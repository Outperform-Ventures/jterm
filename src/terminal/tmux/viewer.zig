const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");

const log = std.log.scoped(.terminal_tmux_viewer);

// TODO: A list of TODOs as I think about them.
// - We need to make startup more robust so session and block can happen
//   out of order.
// - We need to ignore `output` for panes that aren't yet initialized
//   (until capture-panes are complete).
// - We should note what the active window pane is on the tmux side;
//   we can use this at least for initial focus.

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
pub const Viewer = struct {
    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The list of commands we've sent that we want to send and wait
    /// for a response for. We only send one command at a time just
    /// to avoid any possible confusion around ordering.
    command_queue: CommandQueue,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, Pane);

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never re-uses window IDs within a server process lifetime.
        windows: []const Window,

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.fields) |u_field| {
                    if (self == @field(TagType, u_field.name)) {
                        const value = @field(self, u_field.name);
                        switch (u_field.type) {
                            []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,
    };

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,

        pub fn deinit(self: *Window, alloc: Allocator) void {
            self.layout_arena.promote(alloc).deinit();
        }
    };

    pub const Pane = struct {
        terminal: Terminal,

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            self.terminal.deinit(alloc);
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(alloc: Allocator) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        return .{
            .alloc = alloc,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .command_queue = command_queue,
            .windows = .empty,
            .panes = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.deinit(self.alloc);
            self.panes.deinit(self.alloc);
        }
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
        };
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => self.nextCommand(n),
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => return self.defunct(),

            // Any begin and end (even error) is fine! Now we wait for
            // session-changed to get the initial session ID. session-changed
            // is guaranteed to come after the initial command output
            // since if the initial command is `attach` tmux will run that,
            // queue the notification, then do notificatins.
            .block_end, .block_err => {
                self.state = .startup_session;
                return &.{};
            },

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return &.{},
        }
    }

    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => return self.defunct(),

            .session_changed => |info| {
                self.session_id = info.id;

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);
                return self.enterCommandQueue(
                    arena.allocator(),
                    .list_windows,
                ) catch {
                    log.warn("failed to queue command, becoming defunct", .{});
                    return self.defunct();
                };
            },

            else => return &.{},
        }
    }

    fn nextIdle(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .idle);

        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),
            else => return &.{},
        }
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        return switch (n) {
            .enter => unreachable,
            .exit => self.defunct(),

            inline .block_end,
            .block_err,
            => |content, tag| self.receivedCommandOutput(
                content,
                tag == .block_err,
            ) catch {
                log.warn("failed to process command output, becoming defunct", .{});
                return self.defunct();
            },

            .output => |out| output: {
                self.receivedOutput(
                    out.pane_id,
                    out.data,
                ) catch |err| {
                    log.warn(
                        "failed to process output for pane id={}: {}",
                        .{ out.pane_id, err },
                    );
                };

                break :output &.{};
            },

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            .session_changed => |info| self.sessionChanged(info.id) catch {
                log.warn("failed to handle session change, becoming defunct", .{});
                return self.defunct();
            },

            // TODO: There's real logic to do for these.
            .layout_change,
            .window_add,
            => &.{},

            // The active pane changed. We don't care about this because
            // we handle our own focus.
            .window_pane_changed => &.{},

            // We ignore this one. It means a session was created or
            // destroyed. If it was our own session we will get an exit
            // notification very soon. If it is another session we don't
            // care.
            .sessions_changed => &.{},

            // We don't use window names for anything, currently.
            .window_renamed => &.{},

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            .client_detached,
            .client_session_changed,
            => &.{},
        };
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        session_id: usize,
    ) (Allocator.Error || std.Io.Writer.Error)![]const Action {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        var replacement: Viewer = try .init(self.alloc);
        errdefer replacement.deinit();

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        var actions: std.ArrayList(Action) = .empty;
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Setup our command queue
        try actions.appendSlice(
            arena_alloc,
            try replacement.enterCommandQueue(
                arena_alloc,
                .list_windows,
            ),
        );

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        // Set our session ID and jump directly to the list
        self.session_id = session_id;

        assert(self.state == .command_queue);
        return actions.items;
    }

    fn receivedCommandOutput(
        self: *Viewer,
        content: []const u8,
        is_err: bool,
    ) ![]const Action {
        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            // If we have no pending commands, this is unexpected.
            log.info("unexpected block output err={}", .{is_err});
            return &.{};
        };
        self.command_queue.deleteOldest(1);
        defer command.deinit(self.alloc);

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);
        const arena_alloc = arena.allocator();

        // Build up our actions to start with the next command if
        // we have one.
        var actions: std.ArrayList(Action) = .empty;

        // Process our command
        switch (command) {
            .user => {},

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                &actions,
                content,
            ),

            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                content,
            ),

            .pane_visible => |cap| try self.receivedPaneVisible(
                cap.screen_key,
                cap.id,
                content,
            ),
        }

        // After processing commands, we add our next command to
        // execute if we have one. We do this last because command
        // processing may itself queue more commands.
        if (self.command_queue.first()) |next_command| {
            var builder: std.Io.Writer.Allocating = .init(arena_alloc);
            try next_command.formatCommand(&builder.writer);
            try actions.append(
                arena_alloc,
                .{ .command = builder.writer.buffered() },
            );
        }

        // Our command processing should not change our state
        assert(self.state == .command_queue);

        return actions.items;
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // If there is an error, reset our actions to what it was before.
        errdefer actions.shrinkRetainingCapacity(actions.items.len);

        // This stores our new window state from this list-windows output.
        var windows: std.ArrayList(Window) = .empty;
        errdefer windows.deinit(self.alloc);

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch |err| {
                log.info("failed to parse list-windows line: {s}", .{line});
                return err;
            };

            // Parse the layout
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const window_alloc = arena.allocator();
            const layout: Layout = Layout.parseWithChecksum(
                window_alloc,
                data.window_layout,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                return err;
            };

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
                .layout_arena = arena.state,
                .layout = layout,
            });
        }

        // Setup our windows action so the caller can process GUI
        // window changes.
        try actions.append(arena_alloc, .{ .windows = windows.items });

        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.deinit(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows.items) |window| try initLayout(
            self.alloc,
            &self.panes,
            &panes,
            window.layout,
        );

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Get our list of added panes and setup our command queue
        // to populate them.
        // TODO: errdefer cleanup
        {
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                try self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                });
            }
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list
        for (self.windows.items) |*window| window.deinit(self.alloc);
        self.windows.deinit(self.alloc);
        self.windows = windows;

        // Replace our panes
        {
            // First remove our old panes
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                var entry = entry_const;
                entry.value.deinit(self.alloc);
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);
        const screen: *Screen = t.screens.active;

        // Get a VT stream from the terminal so we can send data as-is into
        // it. This will populate the active area too so it won't be exactly
        // correct but we'll get the active contents soon.
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content) catch |err| {
            log.info("failed to process pane history for pane id={}: {}", .{ id, err });
            return err;
        };

        // Populate the active area to be empty since this is only history.
        // We'll fill it with blanks and move the cursor to the top-left.
        t.carriageReturn();
        for (0..t.rows) |_| try t.index();
        t.setCursorPos(1, 1);

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }
    }

    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);

        // Erase the active area and reset the cursor to the top-left
        // before writing the visible content.
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content) catch |err| {
            log.info("failed to process pane visible for pane id={}: {}", .{ id, err });
            return err;
        };
    }

    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(data) catch |err| {
            log.info("failed to process output for pane id={}: {}", .{ id, err });
            return err;
        };
    }

    fn initLayout(
        gpa_alloc: Allocator,
        panes_old: *const PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        gpa_alloc,
                        panes_old,
                        panes_new,
                        l,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                // If we already have this pane, it is already initialized
                // so just copy it over.
                if (panes_old.getEntry(id)) |entry| {
                    gop.value_ptr.* = entry.value_ptr.*;
                    break :pane;
                }

                // TODO: We need to gracefully handle overflow of our
                // max cols/width here. In practice we shouldn't hit this
                // so we cast but its not safe.
                var t: Terminal = try .init(gpa_alloc, .{
                    .cols = @intCast(layout.width),
                    .rows = @intCast(layout.height),
                });
                errdefer t.deinit(gpa_alloc);

                gop.value_ptr.* = .{
                    .terminal = t,
                };
            },
        }
    }

    /// Enters the command queue state from any other state, queueing
    /// the command and returning an action to execute the first command.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        command: Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);

        // Build our command string to send for the action.
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        command.formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };

        // Add our command
        try self.command_queue.ensureUnusedCapacity(self.alloc, 1);
        self.command_queue.appendAssumeCapacity(command);

        // Move into the command queue state
        self.state = .command_queue;

        return self.singleAction(action);
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything because the
    /// command_queue state will automatically send the next command when
    /// it receives output.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        self.state = .defunct;
        return self.singleAction(.exit);
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We wait for an initial
    /// begin/end block that is guaranteed to be sent by tmux for
    /// the initial control mode command. (See tmux server-client.c
    /// where control mode starts).
    startup_block,

    /// After receiving the initial block, we wait for a session-changed
    /// notification to record the initial session ID.
    startup_session,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CapturePane,

    /// Capture visible area for the given pane ID.
    pane_visible: CapturePane,

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            => {},
            .user => |v| alloc.free(v),
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -S - = start at the top of history ("-")
                // -E -1 = end at the last line of history (1 before the
                //   visible area is -1).
                // -t %{d} = target a specific pane ID
                "capture-pane -p -e -q {s}-S - -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_visible => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -t %{d} = target a specific pane ID
                // (no -S/-E = capture visible area only)
                "capture-pane -p -e -q {s}-t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .user => |v| try writer.writeAll(v),
        }
    }
};

/// Format strings used for commands in our viewer.
const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_width,
            .window_height,
            .window_layout,
        },
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .exit },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "list-windows",
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        // Now session changes - should reset everything
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2 @1 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            // pane_history for pane 0 (primary)
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\Hello, world!
                ,
            } },
            // Moves on to pane_visible for pane 0 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
