//! Search thread that handles searching a terminal for a string match.
//! This is expected to run on a dedicated thread to try to prevent too much
//! overhead to other terminal read/write operations.
//!
//! The current architecture of search does acquire global locks for accessing
//! terminal data, so there's still added contention, but we do our best to
//! minimize this by trading off memory usage (copying data to minimize lock
//! time).
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const xev = @import("../../global.zig").xev;
const internal_os = @import("../../os/main.zig");
const BlockingQueue = @import("../../datastruct/main.zig").BlockingQueue;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");

const ScreenSearch = @import("screen.zig").ScreenSearch;

const log = std.log.scoped(.search_thread);

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// The event loop for the search thread.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// Search state. Starts as null and is populated when a search is
/// started (a needle is given).
search: ?Search = null,

/// The options used to initialize this thread.
opts: Options,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(alloc: Allocator, opts: Options) !Thread {
    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    return .{
        .alloc = alloc,
        .mailbox = mailbox,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .opts = opts,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.wakeup.deinit();
    self.stop.deinit();
    self.loop.deinit();
    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);

    if (self.search) |*s| s.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("search thread err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("search thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (comptime builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"search".*);

        // We can run with lower priority than other threads.
        const class: internal_os.macos.QosClass = .utility;
        if (internal_os.macos.setQosClass(class)) {
            log.debug("thread QoS class set class={}", .{class});
        } else |err| {
            log.warn("error setting QoS class err={}", .{err});
        }
    }

    // Start the async handlers
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    // Send an initial wakeup so we drain our mailbox immediately.
    try self.wakeup.notify();

    // Run
    log.debug("starting search thread", .{});
    defer log.debug("starting search thread shutdown", .{});

    // Unlike some of our other threads, we interleave search work
    // with our xev loop so that we can try to make forward search progress
    // while also listening for messages.
    while (true) {
        // If our loop is canceled then we drain our messages and quit.
        if (self.loop.stopped()) {
            while (self.mailbox.pop()) |message| {
                log.debug("mailbox message ignored during shutdown={}", .{message});
            }

            return;
        }

        const s: *Search = if (self.search) |*s| s else {
            // If we're not actively searching, we can block the loop
            // until it does some work.
            try self.loop.run(.once);
            continue;
        };

        if (s.isComplete()) {
            // If our search is complete, there's no more work to do, we
            // can block until we have an xev action.
            try self.loop.run(.once);
            continue;
        }

        // Tick the search. This will trigger any event callbacks, lock
        // for data loading, etc.
        try s.tick(self);

        // We have an active search, so we only want to process messages
        // we have but otherwise return immediately so we can continue the
        // search.
        try self.loop.run(.no_wait);
    }
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .change_needle => |v| try self.changeNeedle(v),
        }
    }
}

/// Change the search term to the given value.
fn changeNeedle(self: *Thread, needle: []const u8) !void {
    log.debug("changing search needle to '{s}'", .{needle});

    // Stop the previous search
    if (self.search) |*s| {
        s.deinit();
        self.search = null;
    }

    // No needle means stop the search.
    if (needle.len == 0) return;

    // Our new search state
    var search: Search = .empty;
    errdefer search.deinit();

    // We need to grab the terminal lock to setup our search state.
    self.opts.mutex.lock();
    defer self.opts.mutex.unlock();
    const t: *Terminal = self.opts.terminal;

    // Go through all our screens, setup our search state.
    //
    // NOTE(mitchellh): Maybe we should only initialize the screen we're
    // currently looking at (the active screen) and then let our screen
    // reconciliation timer add the others later in order to minimize
    // startup latency.
    var it = t.screens.all.iterator();
    while (it.next()) |entry| {
        var screen_search: ScreenSearch = ScreenSearch.init(
            self.alloc,
            entry.value.*,
            needle,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                // We can ignore this (although OOM probably means the whole
                // ship is sinking). Our reconciliation timer will try again
                // later.
                log.warn("error initializing screen search key={} err={}", .{ entry.key, err });
                continue;
            },
        };
        errdefer screen_search.deinit();
        search.screens.put(entry.key, screen_search);
    }

    // Our search state is setup
    self.search = search;
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in wakeup err={}", .{err});
        return .rearm;
    };

    const self = self_.?;

    // When we wake up, we drain the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    self.drainMailbox() catch |err|
        log.warn("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

pub const Options = struct {
    /// Mutex that must be held while reading/writing the terminal.
    mutex: *std.Thread.Mutex,

    /// The terminal data to search.
    terminal: *Terminal,

    /// The callback for events from the search thread along with optional
    /// userdata. This can be null if you don't want to receive events,
    /// which could be useful for a one-time search (although, odd, you
    /// should use our search structures directly then).
    event_cb: ?*const fn (event: Event, userdata: ?*anyopaque) void = null,
    event_userdata: ?*anyopaque = null,
};

/// The type used for sending messages to the thread.
pub const Mailbox = BlockingQueue(Message, 64);

/// The messages that can be sent to the thread.
pub const Message = union(enum) {
    /// Change the search term. If no prior search term is given this
    /// will start a search. If an existing search term is given this will
    /// stop the prior search and start a new one.
    change_needle: []const u8,
};

/// Events that can be emitted from the search thread. The caller
/// chooses to handle these as they see fit.
pub const Event = union(enum) {
    /// Nothing yet. :)
    todo,
};

/// Search state.
const Search = struct {
    /// The searchers for all the screens.
    screens: std.EnumMap(ScreenSet.Key, ScreenSearch),

    pub const empty: Search = .{
        .screens = .init(.{}),
    };

    pub fn deinit(self: *Search) void {
        var it = self.screens.iterator();
        while (it.next()) |entry| entry.value.deinit();
    }

    /// Returns true if all searches on all screens are complete.
    pub fn isComplete(self: *Search) bool {
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            switch (entry.value.state) {
                .complete => {},
                else => return false,
            }
        }

        return true;
    }

    pub fn tick(self: *Search, thread: *Thread) !void {
        // TODO
        _ = self;
        _ = thread;
    }
};

test {
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    try stream.nextSlice("Hello, world");

    var thread: Thread = try .init(alloc, .{
        .mutex = &mutex,
        .terminal = &t,
    });
    defer thread.deinit();

    var os_thread = try std.Thread.spawn(
        .{},
        threadMain,
        .{&thread},
    );

    // Start our search
    _ = thread.mailbox.push(
        .{ .change_needle = "world" },
        .forever,
    );
    try thread.wakeup.notify();

    try thread.stop.notify();
    os_thread.join();
}
