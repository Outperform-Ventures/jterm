//! https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
const std = @import("std");
const Parser = @import("../../osc.zig").Parser;
const OSCCommand = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_semantic_prompt);

pub const Command = union(enum) {
    fresh_line,
    fresh_line_new_prompt: Options,
};

pub const Options = struct {
    aid: ?[:0]const u8,
    cl: ?Click,
    // TODO: more

    pub const init: Options = .{
        .aid = null,
        .click = null,
    };
};

pub const Click = enum {
    line,
    multiple,
    conservative_vertical,
    smart_vertical,
};

/// Parse OSC 133, semantic prompts
pub fn parse(parser: *Parser, _: ?u8) ?*OSCCommand {
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    if (data.len == 0) {
        parser.state = .invalid;
        return null;
    }

    parser.command = command: {
        parse: switch (data[0]) {
            'L' => {
                if (data.len > 1) break :parse;
                break :command .{ .semantic_prompt = .fresh_line };
            },

            else => {},
        }

        // Any fallthroughs are invalid
        parser.state = .invalid;
        return null;
    };

    return &parser.command;
}

test "OSC 133: fresh_line" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;L";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line);
}

test "OSC 133: fresh_line extra contents" {
    const testing = std.testing;

    // Random
    {
        var p: Parser = .init(null);
        const input = "133;Lol";
        for (input) |ch| p.next(ch);
        try testing.expect(p.end(null) == null);
    }

    // Options
    {
        var p: Parser = .init(null);
        const input = "133;L;aid=foo";
        for (input) |ch| p.next(ch);
        try testing.expect(p.end(null) == null);
    }
}
