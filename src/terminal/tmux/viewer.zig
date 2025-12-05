const std = @import("std");
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
    state: State = .startup_block,

    /// The current session ID we're attached to. The default value
    /// is meaningless, because this has to be sent down during
    /// the startup process.
    session_id: usize = 0,

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

    /// Initial state
    pub const init: Viewer = .{};

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
            .exit => {
                self.state = .defunct;
                return .exit;
            },

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

            .exit => {
                self.state = .defunct;
                return .exit;
            },

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

            .exit => {
                self.state = .defunct;
                return .exit;
            },

            .block_end,
            .block_err,
            => |content| switch (self.state) {
                .startup_block, .startup_session, .defunct => unreachable,
                .list_windows => {
                    // TODO: parse the content
                    _ = content;
                    return null;
                },
            },

            // TODO: Use exhaustive matching here, determine if we need
            // to handle the other cases.
            else => return null,
        }
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
    var viewer: Viewer = .init;
    try testing.expectEqual(.exit, viewer.next(.exit).?);
    try testing.expect(viewer.next(.exit) == null);
}

test "initial flow" {
    var viewer: Viewer = .init;

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
    }

    try testing.expectEqual(.exit, viewer.next(.exit).?);
    try testing.expect(viewer.next(.exit) == null);
}
