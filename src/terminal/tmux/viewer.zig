const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const control = @import("control.zig");
const output = @import("output.zig");

const log = std.log.scoped(.terminal_tmux_viewer);

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

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

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
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,
    };

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        // TODO: more fields, obviously!
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(alloc: Allocator) Viewer {
        return .{
            .alloc = alloc,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .windows = .empty,
            .action_arena = .{},
        };
    }

    pub fn deinit(self: *Viewer) void {
        self.windows.deinit(self.alloc);
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) Allocator.Error![]const Action {
        return switch (input) {
            .tmux => try self.nextTmux(input.tmux),
        };
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) Allocator.Error![]const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => try self.nextStartupBlock(n),
            .startup_session => try self.nextStartupSession(n),
            .idle => try self.nextIdle(n),

            // Once we're in the main states, there's a bunch of shared
            // logic so we centralize it.
            .list_windows => try self.nextCommand(n),
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) Allocator.Error![]const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => return try self.defunct(),

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
    ) Allocator.Error![]const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => return try self.defunct(),

            .session_changed => |info| {
                self.session_id = info.id;
                self.state = .list_windows;
                return try self.singleAction(.{ .command = std.fmt.comptimePrint(
                    "list-windows -F '{s}'\n",
                    .{comptime Format.list_windows.comptimeFormat()},
                ) });
            },

            else => return &.{},
        }
    }

    fn nextIdle(
        self: *Viewer,
        n: control.Notification,
    ) Allocator.Error![]const Action {
        assert(self.state == .idle);

        switch (n) {
            .enter => unreachable,
            .exit => return try self.defunct(),
            else => return &.{},
        }
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) Allocator.Error![]const Action {
        switch (n) {
            .enter => unreachable,

            .exit => return try self.defunct(),

            inline .block_end,
            .block_err,
            => |content, tag| switch (self.state) {
                .startup_block,
                .startup_session,
                .idle,
                .defunct,
                => unreachable,

                .list_windows => {
                    // Move to defunct on error blocks.
                    if (comptime tag == .block_err) return try self.defunct();
                    return self.receivedListWindows(content) catch return try self.defunct();
                },
            },

            // TODO: Use exhaustive matching here, determine if we need
            // to handle the other cases.
            else => return &.{},
        }
    }

    fn receivedListWindows(
        self: *Viewer,
        content: []const u8,
    ) ![]const Action {
        assert(self.state == .list_windows);

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

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
            });
        }

        // Replace our window list
        self.windows.deinit(self.alloc);
        self.windows = windows;

        // Go into the idle state
        self.state = .idle;

        // TODO: Diff with prior window state, dispatch capture-pane
        // requests to collect all of the screen contents, other terminal
        // state, etc.

        return try self.singleAction(.{ .windows = self.windows.items });
    }

    /// Helper to return a single action. The input action must not use
    /// any allocated memory from `action_arena` since this will reset
    /// the arena.
    fn singleAction(
        self: *Viewer,
        action: Action,
    ) Allocator.Error![]const Action {
        // Make our actual arena
        var arena = self.action_arena.promote(self.alloc);

        // Need to be careful to update our internal state after
        // doing allocations since the arena takes a copy of the state.
        defer self.action_arena = arena.state;

        // Free everything. We could retain some state here if we wanted
        // but I don't think its worth it.
        _ = arena.reset(.free_all);

        // Make our single action slice.
        const alloc = arena.allocator();
        return try alloc.dupe(Action, &.{action});
    }

    fn defunct(self: *Viewer) Allocator.Error![]const Action {
        self.state = .defunct;
        return try self.singleAction(.exit);
    }
};

const State = union(enum) {
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

    /// We're waiting on a list-windows response from tmux. This will
    /// be used to resynchronize our entire window state.
    list_windows,

    /// Idle state, we're not actually doing anything right now except
    /// waiting for more events from tmux that may change our behavior.
    idle,
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

test "immediate exit" {
    var viewer = Viewer.init(testing.allocator);
    defer viewer.deinit();
    const actions = try viewer.next(.{ .tmux = .exit });
    try testing.expectEqual(1, actions.len);
    try testing.expectEqual(.exit, actions[0]);
    const actions2 = try viewer.next(.{ .tmux = .exit });
    try testing.expectEqual(0, actions2.len);
}

test "initial flow" {
    var viewer = Viewer.init(testing.allocator);
    defer viewer.deinit();

    // First we receive the initial block end
    const actions0 = try viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expectEqual(0, actions0.len);

    // Then we receive session-changed with the initial session
    {
        const actions = try viewer.next(.{ .tmux = .{ .session_changed = .{
            .id = 42,
            .name = "main",
        } } });
        try testing.expectEqual(1, actions.len);
        try testing.expect(actions[0] == .command);
        try testing.expect(std.mem.startsWith(u8, actions[0].command, "list-windows"));
        try testing.expectEqual(42, viewer.session_id);
    }

    // Simulate our list-windows command
    {
        const actions = try viewer.next(.{ .tmux = .{
            .block_end =
            \\$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
            ,
        } });
        try testing.expectEqual(1, actions.len);
        try testing.expect(actions[0] == .windows);
        try testing.expectEqual(1, actions[0].windows.len);
    }

    const exit_actions = try viewer.next(.{ .tmux = .exit });
    try testing.expectEqual(1, exit_actions.len);
    try testing.expectEqual(.exit, exit_actions[0]);
    const final_actions = try viewer.next(.{ .tmux = .exit });
    try testing.expectEqual(0, final_actions.len);
}
