const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    MissingValue,
    InvalidValue,
    InvalidEnv,
    UnsupportedOption,
};

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Parsed = struct {
    pub const OsWindowState = enum {
        normal,
        maximized,
        minimized,
        hidden,
    };

    title: ?[]const u8 = null,
    os_window_state: OsWindowState = .normal,
    env: []const EnvPair = &.{},
    argv: []const []const u8 = &.{},

    pub fn deinit(self: *Parsed, alloc: Allocator) void {
        if (self.env.len > 0) alloc.free(self.env);
        if (self.argv.len > 0) alloc.free(self.argv);
        self.* = undefined;
    }
};

pub fn parseArgs(
    alloc: Allocator,
    args: []const []const u8,
) (Allocator.Error || ParseError)!Parsed {
    var env_list: std.ArrayList(EnvPair) = .empty;
    defer env_list.deinit(alloc);

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(alloc);

    var title: ?[]const u8 = null;
    var os_window_state: Parsed.OsWindowState = .normal;
    var parse_options = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (parse_options and std.mem.eql(u8, arg, "--")) {
            parse_options = false;
            continue;
        }

        if (parse_options and std.mem.eql(u8, arg, "--type")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try parseType(args[i]);
            continue;
        }

        if (parse_options and std.mem.startsWith(u8, arg, "--type=")) {
            try parseType(arg["--type=".len..]);
            continue;
        }

        if (parse_options and std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (args[i].len == 0) return error.MissingValue;
            title = args[i];
            continue;
        }

        if (parse_options and std.mem.startsWith(u8, arg, "--title=")) {
            const value = arg["--title=".len..];
            if (value.len == 0) return error.MissingValue;
            title = value;
            continue;
        }

        if (parse_options and std.mem.eql(u8, arg, "--os-window-state")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            os_window_state = try parseOsWindowState(args[i]);
            continue;
        }

        if (parse_options and std.mem.startsWith(u8, arg, "--os-window-state=")) {
            os_window_state = try parseOsWindowState(arg["--os-window-state=".len..]);
            continue;
        }

        if (parse_options and std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try env_list.append(alloc, try parseEnv(args[i]));
            continue;
        }

        if (parse_options and std.mem.startsWith(u8, arg, "--env=")) {
            try env_list.append(alloc, try parseEnv(arg["--env=".len..]));
            continue;
        }

        if (parse_options and std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedOption;
        }

        parse_options = false;
        try argv_list.append(alloc, arg);
    }

    var env: []EnvPair = &.{};
    if (env_list.items.len > 0) env = try env_list.toOwnedSlice(alloc);

    var argv: []const []const u8 = &.{};
    if (argv_list.items.len > 0) argv = try argv_list.toOwnedSlice(alloc);

    return .{
        .title = title,
        .os_window_state = os_window_state,
        .env = env,
        .argv = argv,
    };
}

pub fn buildLaunchText(
    alloc: Allocator,
    parsed: Parsed,
) Allocator.Error!?[]u8 {
    if (parsed.env.len == 0 and parsed.argv.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    if (parsed.env.len > 0) {
        try out.appendSlice(alloc, "export ");
        for (parsed.env, 0..) |pair, i| {
            if (i > 0) try out.append(alloc, ' ');
            try out.appendSlice(alloc, pair.key);
            try out.append(alloc, '=');
            try appendShellQuoted(alloc, &out, pair.value);
        }

        if (parsed.argv.len > 0) try out.appendSlice(alloc, "; ");
    }

    if (parsed.argv.len > 0) {
        for (parsed.argv, 0..) |arg, i| {
            if (i > 0) try out.append(alloc, ' ');
            try appendShellQuoted(alloc, &out, arg);
        }
    }

    try out.append(alloc, '\n');
    return @as(?[]u8, try out.toOwnedSlice(alloc));
}

fn parseType(value: []const u8) ParseError!void {
    if (value.len == 0) return error.MissingValue;
    if (std.mem.eql(u8, value, "os-window")) return;
    if (std.mem.eql(u8, value, "window")) return;
    return error.InvalidValue;
}

fn parseEnv(value: []const u8) ParseError!EnvPair {
    const eql = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidEnv;
    const key = value[0..eql];
    const env_value = value[eql + 1 ..];

    if (!isValidEnvKey(key)) return error.InvalidEnv;

    return .{
        .key = key,
        .value = env_value,
    };
}

fn parseOsWindowState(value: []const u8) ParseError!Parsed.OsWindowState {
    if (value.len == 0) return error.MissingValue;
    if (std.mem.eql(u8, value, "normal")) return .normal;
    if (std.mem.eql(u8, value, "maximized")) return .maximized;
    if (std.mem.eql(u8, value, "minimized")) return .minimized;
    if (std.mem.eql(u8, value, "hidden")) return .hidden;
    return error.InvalidValue;
}

fn isValidEnvKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!isEnvHeadChar(key[0])) return false;
    for (key[1..]) |c| {
        if (!isEnvTailChar(c)) return false;
    }
    return true;
}

fn isEnvHeadChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        c == '_';
}

fn isEnvTailChar(c: u8) bool {
    return isEnvHeadChar(c) or (c >= '0' and c <= '9');
}

fn appendShellQuoted(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) Allocator.Error!void {
    try out.append(alloc, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
            continue;
        }

        try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
}

test "parseArgs supports kitty-style launch fields" {
    const testing = std.testing;

    const args = [_][]const u8{
        "--type=os-window",
        "--title=symph: demo",
        "--env=SYMPH_WINDOW=demo",
        "bash",
        "-lc",
        "symph me demo",
    };

    var parsed = try parseArgs(testing.allocator, args[0..]);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("symph: demo", parsed.title.?);
    try testing.expectEqual(Parsed.OsWindowState.normal, parsed.os_window_state);
    try testing.expectEqual(@as(usize, 1), parsed.env.len);
    try testing.expectEqualStrings("SYMPH_WINDOW", parsed.env[0].key);
    try testing.expectEqualStrings("demo", parsed.env[0].value);
    try testing.expectEqual(@as(usize, 3), parsed.argv.len);
    try testing.expectEqualStrings("bash", parsed.argv[0]);
}

test "parseArgs supports os-window-state" {
    const testing = std.testing;

    const args = [_][]const u8{
        "--type=os-window",
        "--os-window-state=minimized",
        "echo",
        "hi",
    };

    var parsed = try parseArgs(testing.allocator, args[0..]);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(Parsed.OsWindowState.minimized, parsed.os_window_state);
    try testing.expectEqual(@as(usize, 2), parsed.argv.len);
}

test "parseArgs rejects unknown os-window-state" {
    const testing = std.testing;

    const args = [_][]const u8{
        "--os-window-state=fullscreen",
    };

    try testing.expectError(error.InvalidValue, parseArgs(testing.allocator, args[0..]));
}

test "parseArgs supports -- separator" {
    const testing = std.testing;

    const args = [_][]const u8{
        "--title=foo",
        "--",
        "--not-an-option",
    };

    var parsed = try parseArgs(testing.allocator, args[0..]);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), parsed.argv.len);
    try testing.expectEqualStrings("--not-an-option", parsed.argv[0]);
}

test "buildLaunchText exports env and executes command" {
    const testing = std.testing;

    const parsed: Parsed = .{
        .env = &.{.{ .key = "SYMPH_WINDOW", .value = "demo" }},
        .argv = &.{ "bash", "-lc", "symph me demo" },
    };

    const text = (try buildLaunchText(testing.allocator, parsed)).?;
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        "export SYMPH_WINDOW='demo'; 'bash' '-lc' 'symph me demo'\n",
        text,
    );
}
