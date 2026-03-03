const std = @import("std");

pub const Error = error{
    InvalidExpression,
    InvalidNumber,
};

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Candidate = struct {
    id: u64,
    pid: ?u64 = null,
    num: ?u64 = null,
    title: ?[]const u8 = null,
    cmdline: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    session: ?[]const u8 = null,
    neighbor: ?[]const u8 = null,
    focused: bool = false,
    active: bool = false,
    recent_rank: u64 = 0,
    env: []const EnvPair = &.{},
    vars: []const EnvPair = &.{},
};

const EnvTerm = struct {
    key: []const u8,
    pattern: []const u8,
};

const Term = union(enum) {
    id: u64,
    pid: u64,
    num: u64,
    title: []const u8,
    cmdline: []const u8,
    cwd: []const u8,
    session: []const u8,
    neighbor: []const u8,
    focused: bool,
    active: bool,
    recent: u64,
    env: EnvTerm,
    var_: EnvTerm,
};

fn parseTerm(raw: []const u8) Error!Term {
    const idx = std.mem.indexOfScalar(u8, raw, ':') orelse return error.InvalidExpression;
    const key = std.mem.trim(u8, raw[0..idx], " \t");
    const value = std.mem.trim(u8, raw[idx + 1 ..], " \t");
    if (value.len == 0) return error.InvalidExpression;

    if (std.mem.eql(u8, key, "id")) {
        return .{ .id = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidNumber };
    }
    if (std.mem.eql(u8, key, "pid")) {
        return .{ .pid = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidNumber };
    }
    if (std.mem.eql(u8, key, "num")) {
        return .{ .num = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidNumber };
    }
    if (std.mem.eql(u8, key, "title")) return .{ .title = value };
    if (std.mem.eql(u8, key, "cmdline")) return .{ .cmdline = value };
    if (std.mem.eql(u8, key, "cwd")) return .{ .cwd = value };
    if (std.mem.eql(u8, key, "session")) return .{ .session = value };
    if (std.mem.eql(u8, key, "neighbor")) return .{ .neighbor = value };
    if (std.mem.eql(u8, key, "env")) {
        return .{ .env = try parseEnvTerm(value) };
    }
    if (std.mem.eql(u8, key, "var")) {
        return .{ .var_ = try parseEnvTerm(value) };
    }
    if (std.mem.eql(u8, key, "recent")) {
        return .{ .recent = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidNumber };
    }
    if (std.mem.eql(u8, key, "state")) {
        if (std.mem.eql(u8, value, "focused")) return .{ .focused = true };
        if (std.mem.eql(u8, value, "unfocused")) return .{ .focused = false };
        if (std.mem.eql(u8, value, "active")) return .{ .active = true };
        if (std.mem.eql(u8, value, "inactive")) return .{ .active = false };
        return error.InvalidExpression;
    }

    return error.InvalidExpression;
}

pub fn matches(expr: []const u8, candidate: Candidate) Error!bool {
    var or_groups = std.mem.splitSequence(u8, expr, "||");
    var saw_group = false;
    while (or_groups.next()) |group_raw| {
        saw_group = true;
        if (try matchesGroup(group_raw, candidate)) return true;
    }

    if (!saw_group) return true;
    return false;
}

fn matchesGroup(expr: []const u8, candidate: Candidate) Error!bool {
    var terms = std.mem.splitAny(u8, expr, ",");
    var saw_term = false;
    while (terms.next()) |term_raw| {
        const term = std.mem.trim(u8, term_raw, " \t");
        if (term.len == 0) continue;
        saw_term = true;

        const parsed = try parseTerm(term);
        const ok = switch (parsed) {
            .id => |v| candidate.id == v,
            .pid => |v| candidate.pid != null and candidate.pid.? == v,
            .num => |v| candidate.num != null and candidate.num.? == v,
            .title => |v| if (candidate.title) |title| std.mem.indexOf(u8, title, v) != null else false,
            .cmdline => |v| if (candidate.cmdline) |cmdline| std.mem.indexOf(u8, cmdline, v) != null else false,
            .cwd => |v| if (candidate.cwd) |cwd| std.mem.indexOf(u8, cwd, v) != null else false,
            .session => |v| if (candidate.session) |session| std.mem.indexOf(u8, session, v) != null else false,
            .neighbor => |v| if (candidate.neighbor) |neighbor| std.mem.indexOf(u8, neighbor, v) != null else false,
            .focused => |v| candidate.focused == v,
            .active => |v| candidate.active == v,
            .recent => |v| if (v == 0)
                candidate.recent_rank == 1
            else
                candidate.recent_rank == v,
            .env => |v| matchEnv(candidate.env, v.key, v.pattern),
            .var_ => |v| matchEnv(candidate.vars, v.key, v.pattern),
        };
        if (!ok) return false;
    }

    return true;
}

fn parseEnvTerm(value: []const u8) Error!EnvTerm {
    const eql_idx = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidExpression;
    const key = std.mem.trim(u8, value[0..eql_idx], " \t");
    const pattern = std.mem.trim(u8, value[eql_idx + 1 ..], " \t");
    if (key.len == 0 or pattern.len == 0) return error.InvalidExpression;
    return .{
        .key = key,
        .pattern = pattern,
    };
}

fn matchEnv(
    env: []const EnvPair,
    key: []const u8,
    pattern: []const u8,
) bool {
    for (env) |entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        if (matchPattern(pattern, entry.value)) return true;
    }

    return false;
}

fn matchPattern(
    pattern: []const u8,
    value: []const u8,
) bool {
    const anchored_start = pattern.len > 0 and pattern[0] == '^';
    const anchored_end = pattern.len > 1 and pattern[pattern.len - 1] == '$';

    if (anchored_start and anchored_end) {
        if (pattern.len <= 2) return value.len == 0;
        return std.mem.eql(u8, value, pattern[1 .. pattern.len - 1]);
    }

    if (anchored_start) {
        return std.mem.startsWith(u8, value, pattern[1..]);
    }

    if (anchored_end) {
        return std.mem.endsWith(u8, value, pattern[0 .. pattern.len - 1]);
    }

    return std.mem.indexOf(u8, value, pattern) != null;
}

test "matches id and title" {
    const testing = std.testing;
    const c: Candidate = .{
        .id = 7,
        .title = "shell: project",
    };

    try testing.expect(try matches("id:7,title:project", c));
    try testing.expect(!(try matches("id:8", c)));
}

test "matches cwd, focused, and recent rank" {
    const testing = std.testing;
    const c: Candidate = .{
        .id = 1,
        .cwd = "/Users/jkuechly/code/jterm",
        .focused = true,
        .recent_rank = 1,
    };

    try testing.expect(try matches("cwd:jterm,state:focused,recent:1,state:inactive", .{
        .id = c.id,
        .cwd = c.cwd,
        .focused = c.focused,
        .recent_rank = c.recent_rank,
        .active = false,
    }));
    try testing.expect(!(try matches("recent:2", c)));
    try testing.expect(try matches("recent:0", c));
}

test "matches env key with anchored pattern" {
    const testing = std.testing;
    const c: Candidate = .{
        .id = 3,
        .env = &.{
            .{ .key = "SYMPH_WINDOW", .value = "alpha" },
        },
    };

    try testing.expect(try matches("env:SYMPH_WINDOW=^alpha$", c));
    try testing.expect(!(try matches("env:SYMPH_WINDOW=^beta$", c)));
}

test "matches pid cmdline var and OR groups" {
    const testing = std.testing;
    const c: Candidate = .{
        .id = 12,
        .pid = 42001,
        .cmdline = "bash -lc symph me demo",
        .vars = &.{.{ .key = "role", .value = "worker" }},
    };

    try testing.expect(try matches("pid:42001,cmdline:symph,var:role=^worker$", c));
    try testing.expect(try matches("id:999||id:12", c));
    try testing.expect(!(try matches("id:999||var:role=^api$", c)));
}

test "invalid expressions fail" {
    const testing = std.testing;
    const c: Candidate = .{ .id = 1 };

    try testing.expectError(error.InvalidExpression, matches("id", c));
    try testing.expectError(error.InvalidNumber, matches("id:abc", c));
    try testing.expectError(error.InvalidExpression, matches("state:weird", c));
    try testing.expectError(error.InvalidExpression, matches("env:FOO", c));
    try testing.expectError(error.InvalidExpression, matches("var:KEY", c));
}

test "matches fuzz random expressions does not panic" {
    var prng = std.Random.DefaultPrng.init(0x6a31_4ef2_d5aa_9001);
    const random = prng.random();

    const candidate: Candidate = .{
        .id = 42,
        .title = "demo",
        .cwd = "/tmp",
        .focused = true,
    };

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const len = random.uintLessThan(usize, 64);
        var buf: [64]u8 = undefined;
        random.bytes(buf[0..len]);
        _ = matches(buf[0..len], candidate) catch continue;
    }
}
