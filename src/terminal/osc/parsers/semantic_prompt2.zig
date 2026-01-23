//! https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
const std = @import("std");
const Parser = @import("../../osc.zig").Parser;
const OSCCommand = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_semantic_prompt);

pub const Command = union(enum) {
    fresh_line,
    fresh_line_new_prompt: Options,
    new_command: Options,
    prompt_start: Options,
    end_prompt_start_input: Options,
    end_prompt_start_input_terminate_eol: Options,
};

pub const Options = struct {
    aid: ?[:0]const u8,
    cl: ?Click,
    prompt_kind: ?PromptKind,
    exit_code: ?i32,
    err: ?[:0]const u8,

    pub const init: Options = .{
        .aid = null,
        .cl = null,
        .prompt_kind = null,
        .exit_code = null,
        .err = null,
    };

    pub fn parse(self: *Options, it: *KVIterator) void {
        while (it.next()) |kv| {
            const key = kv.key orelse continue;
            if (std.mem.eql(u8, key, "aid")) {
                self.aid = kv.value;
            } else if (std.mem.eql(u8, key, "cl")) cl: {
                const value = kv.value orelse break :cl;
                self.cl = std.meta.stringToEnum(Click, value);
            } else if (std.mem.eql(u8, key, "k")) k: {
                const value = kv.value orelse break :k;
                if (value.len != 1) break :k;
                self.prompt_kind = .init(value[0]);
            } else if (std.mem.eql(u8, key, "err")) {
                self.err = kv.value;
            } else if (key.len == 0) exit_code: {
                const value = kv.value orelse break :exit_code;
                self.exit_code = std.fmt.parseInt(i32, value, 10) catch break :exit_code;
            } else {
                log.info("OSC 133: unknown semantic prompt option: {s}", .{key});
            }
        }
    }
};

pub const Click = enum {
    line,
    multiple,
    conservative_vertical,
    smart_vertical,
};

pub const PromptKind = enum {
    initial,
    right,
    continuation,
    secondary,

    pub fn init(c: u8) ?PromptKind {
        return switch (c) {
            'i' => .initial,
            'r' => .right,
            'c' => .continuation,
            's' => .secondary,
            else => null,
        };
    }
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

    // All valid cases terminate within this block. Any fallthroughs
    // are invalid. This makes some of our parse logic a little less
    // repetitive.
    valid: {
        switch (data[0]) {
            'A' => fresh_line: {
                parser.command = .{ .semantic_prompt = .{ .fresh_line_new_prompt = .init } };
                if (data.len == 1) break :fresh_line;
                if (data[1] != ';') break :valid;
                var it = KVIterator.init(writer) catch break :valid;
                parser.command.semantic_prompt.fresh_line_new_prompt.parse(&it);
            },

            'B' => end_prompt: {
                parser.command = .{ .semantic_prompt = .{ .end_prompt_start_input = .init } };
                if (data.len == 1) break :end_prompt;
                if (data[1] != ';') break :valid;
                var it = KVIterator.init(writer) catch break :valid;
                parser.command.semantic_prompt.end_prompt_start_input.parse(&it);
            },

            'I' => end_prompt_line: {
                parser.command = .{ .semantic_prompt = .{ .end_prompt_start_input_terminate_eol = .init } };
                if (data.len == 1) break :end_prompt_line;
                if (data[1] != ';') break :valid;
                var it = KVIterator.init(writer) catch break :valid;
                parser.command.semantic_prompt.end_prompt_start_input_terminate_eol.parse(&it);
            },

            'L' => {
                if (data.len > 1) break :valid;
                parser.command = .{ .semantic_prompt = .fresh_line };
            },

            'N' => new_command: {
                parser.command = .{ .semantic_prompt = .{ .new_command = .init } };
                if (data.len == 1) break :new_command;
                if (data[1] != ';') break :valid;
                var it = KVIterator.init(writer) catch break :valid;
                parser.command.semantic_prompt.new_command.parse(&it);
            },

            'P' => prompt_start: {
                parser.command = .{ .semantic_prompt = .{ .prompt_start = .init } };
                if (data.len == 1) break :prompt_start;
                if (data[1] != ';') break :valid;
                var it = KVIterator.init(writer) catch break :valid;
                parser.command.semantic_prompt.prompt_start.parse(&it);
            },

            else => break :valid,
        }

        return &parser.command;
    }
    // Any fallthroughs are invalid
    parser.state = .invalid;
    return null;
}

const KVIterator = struct {
    index: usize,
    string: []u8,

    pub const KV = struct {
        key: ?[:0]u8,
        value: ?[:0]u8,

        pub const empty: KV = .{
            .key = null,
            .value = null,
        };
    };

    pub fn init(writer: *std.Io.Writer) std.Io.Writer.Error!KVIterator {
        // Add a semicolon to make it easier to find and sentinel terminate
        // the values.
        try writer.writeByte(';');
        return .{
            .index = 0,
            .string = writer.buffered()[2..],
        };
    }

    pub fn next(self: *KVIterator) ?KV {
        if (self.index >= self.string.len) return null;

        const kv = kv: {
            const index = std.mem.indexOfScalarPos(
                u8,
                self.string,
                self.index,
                ';',
            ) orelse {
                self.index = self.string.len;
                return null;
            };
            self.string[index] = 0;
            const kv = self.string[self.index..index :0];
            self.index = index + 1;
            break :kv kv;
        };

        // If we have an empty item, we return a null key and value.
        //
        // This allows for trailing semicolons, but also lets us parse
        // (or rather, ignore) empty fields; for example `a=b;;e=f`.
        if (kv.len < 1) return .empty;

        const key = key: {
            const index = std.mem.indexOfScalar(
                u8,
                kv,
                '=',
            ) orelse {
                // If there is no '=' return entire `kv` string as the key and
                // a null value.
                return .{
                    .key = kv,
                    .value = null,
                };
            };

            kv[index] = 0;
            break :key kv[0..index :0];
        };
        const value = kv[key.len + 1 .. :0];

        return .{
            .key = key,
            .value = value,
        };
    }
};

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

test "OSC 133: fresh_line_new_prompt" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.aid == null);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.cl == null);
}

test "OSC 133: fresh_line_new_prompt with aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=14";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expectEqualStrings("14", cmd.semantic_prompt.fresh_line_new_prompt.aid.?);
}

test "OSC 133: fresh_line_new_prompt with '=' in aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=a=b";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expectEqualStrings("a=b", cmd.semantic_prompt.fresh_line_new_prompt.aid.?);
}

test "OSC 133: fresh_line_new_prompt with cl=line" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.cl == .line);
}

test "OSC 133: fresh_line_new_prompt with cl=multiple" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;cl=multiple";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.cl == .multiple);
}

test "OSC 133: fresh_line_new_prompt with invalid cl" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;cl=invalid";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.cl == null);
}

test "OSC 133: fresh_line_new_prompt with trailing ;" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
}

test "OSC 133: fresh_line_new_prompt with bare key" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;barekey";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.aid == null);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.cl == null);
}

test "OSC 133: fresh_line_new_prompt with multiple options" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=foo;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .fresh_line_new_prompt);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.fresh_line_new_prompt.aid.?);
    try testing.expect(cmd.semantic_prompt.fresh_line_new_prompt.cl == .line);
}

test "OSC 133: prompt_start" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .prompt_start);
    try testing.expect(cmd.semantic_prompt.prompt_start.prompt_kind == null);
}

test "OSC 133: prompt_start with k=i" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=i";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .prompt_start);
    try testing.expect(cmd.semantic_prompt.prompt_start.prompt_kind == .initial);
}

test "OSC 133: prompt_start with k=r" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=r";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .prompt_start);
    try testing.expect(cmd.semantic_prompt.prompt_start.prompt_kind == .right);
}

test "OSC 133: prompt_start with k=c" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=c";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .prompt_start);
    try testing.expect(cmd.semantic_prompt.prompt_start.prompt_kind == .continuation);
}

test "OSC 133: prompt_start with k=s" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=s";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .prompt_start);
    try testing.expect(cmd.semantic_prompt.prompt_start.prompt_kind == .secondary);
}

test "OSC 133: prompt_start with invalid k" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=x";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .prompt_start);
    try testing.expect(cmd.semantic_prompt.prompt_start.prompt_kind == null);
}

test "OSC 133: prompt_start extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Pextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: new_command" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .new_command);
    try testing.expect(cmd.semantic_prompt.new_command.aid == null);
    try testing.expect(cmd.semantic_prompt.new_command.cl == null);
}

test "OSC 133: new_command with aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .new_command);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.new_command.aid.?);
}

test "OSC 133: new_command with cl=line" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .new_command);
    try testing.expect(cmd.semantic_prompt.new_command.cl == .line);
}

test "OSC 133: new_command with multiple options" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N;aid=foo;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .new_command);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.new_command.aid.?);
    try testing.expect(cmd.semantic_prompt.new_command.cl == .line);
}

test "OSC 133: new_command extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Nextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_prompt_start_input" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;B";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .end_prompt_start_input);
}

test "OSC 133: end_prompt_start_input extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Bextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_prompt_start_input with options" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;B;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .end_prompt_start_input);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.end_prompt_start_input.aid.?);
}

test "OSC 133: end_prompt_start_input_terminate_eol" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;I";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .end_prompt_start_input_terminate_eol);
}

test "OSC 133: end_prompt_start_input_terminate_eol extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Iextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_prompt_start_input_terminate_eol with options" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;I;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt == .end_prompt_start_input_terminate_eol);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.end_prompt_start_input_terminate_eol.aid.?);
}
