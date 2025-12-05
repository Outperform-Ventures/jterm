const std = @import("std");
const Allocator = std.mem.Allocator;
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

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,
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
        };
    }

    pub fn deinit(self: *Viewer) void {
        self.windows.deinit(self.alloc);
    }

    /// Send in the next tmux notification we got from the control mode
    /// protocol. The return value is any action that needs to be taken
    /// in reaction to this notification (could be none).
    pub fn next(self: *Viewer, n: control.Notification) ?Action {
        return switch (self.state) {
            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct null;
            },

            // Once we're in the main states, there's a bunch of shared
            // logic so we centralize it.
            .list_windows => self.nextCommand(n),
        };
    }

    fn nextStartupBlock(self: *Viewer, n: control.Notification) ?Action {
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
                return null;
            },

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return null,
        }
    }

    fn nextStartupSession(self: *Viewer, n: control.Notification) ?Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => return self.defunct(),

            .session_changed => |info| {
                self.session_id = info.id;
                self.state = .list_windows;
                return .{ .command = std.fmt.comptimePrint(
                    "list-windows -F '{s}'",
                    .{comptime Format.list_windows.comptimeFormat()},
                ) };
            },

            else => return null,
        }
    }

    fn nextCommand(self: *Viewer, n: control.Notification) ?Action {
        assert(self.state != .startup_block);
        assert(self.state != .startup_session);
        assert(self.state != .defunct);

        switch (n) {
            .enter => unreachable,

            .exit => return self.defunct(),

            inline .block_end,
            .block_err,
            => |content, tag| switch (self.state) {
                .startup_block, .startup_session, .defunct => unreachable,

                .list_windows => {
                    // Move to defunct on error blocks.
                    if (comptime tag == .block_err) return self.defunct();
                    return self.receivedListWindows(content) catch self.defunct();
                },
            },

            // TODO: Use exhaustive matching here, determine if we need
            // to handle the other cases.
            else => return null,
        }
    }

    fn receivedListWindows(
        self: *Viewer,
        content: []const u8,
    ) !Action {
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

        // TODO: Diff our prior windows

        // Replace our window list
        self.windows.deinit(self.alloc);
        self.windows = windows;

        return .exit;
    }

    fn defunct(self: *Viewer) Action {
        self.state = .defunct;
        // In the future we may want to deallocate a bunch of memory
        // when we go defunct.
        return .exit;
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

    /// We're waiting on a list-windows response from tmux.
    list_windows,
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
    try testing.expectEqual(.exit, viewer.next(.exit).?);
    try testing.expect(viewer.next(.exit) == null);
}

test "initial flow" {
    var viewer = Viewer.init(testing.allocator);
    defer viewer.deinit();

    // First we receive the initial block end
    try testing.expect(viewer.next(.{ .block_end = "" }) == null);

    // Then we receive session-changed with the initial session
    {
        const action = viewer.next(.{ .session_changed = .{
            .id = 42,
            .name = "main",
        } }).?;
        try testing.expect(action == .command);
        try testing.expect(std.mem.startsWith(u8, action.command, "list-windows"));
        try testing.expectEqual(42, viewer.session_id);
        // log.warn("{s}", .{action.command});
    }

    // Simulate our list-windows command
    {
        const action = viewer.next(.{
            .block_end =
            \\$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
            ,
        }).?;
        _ = action;
    }

    try testing.expectEqual(.exit, viewer.next(.exit).?);
    try testing.expect(viewer.next(.exit) == null);
}
