const std = @import("std");
const lib_alloc = @import("../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const osc = @import("osc.zig");

pub const GhosttyOscParser = extern struct {
    parser: *osc.Parser,
};

pub const Result = enum(c_int) {
    success = 0,
    out_of_memory = -1,
};

pub fn ghostty_vt_osc_new(
    c_alloc: *const CAllocator,
    result: *GhosttyOscParser,
) callconv(.c) Result {
    const alloc = c_alloc.zig();
    const ptr = alloc.create(osc.Parser) catch return .out_of_memory;
    ptr.* = .initAlloc(alloc);
    result.* = .{ .parser = ptr };
    return .success;
}

pub fn ghostty_vt_osc_free(parser: GhosttyOscParser) callconv(.c) void {
    const alloc = parser.parser.alloc.?;
    parser.parser.deinit();
    alloc.destroy(parser.parser);
}

test {
    _ = lib_alloc;
}

test "osc" {
    const testing = std.testing;
    var p: GhosttyOscParser = undefined;
    try testing.expectEqual(Result.success, ghostty_vt_osc_new(
        &lib_alloc.test_allocator,
        &p,
    ));
    ghostty_vt_osc_free(p);
}
