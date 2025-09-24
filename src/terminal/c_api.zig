const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const lib_alloc = @import("../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const osc = @import("osc.zig");

/// C: GhosttyOscParser
pub const GhosttyOscParser = *osc.Parser;

/// C: GhosttyResult
pub const Result = enum(c_int) {
    success = 0,
    out_of_memory = -1,
};

pub fn ghostty_vt_osc_new(
    alloc_: ?*const CAllocator,
    result: *GhosttyOscParser,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(osc.Parser) catch
        return .out_of_memory;
    ptr.* = .initAlloc(alloc);
    result.* = ptr;
    return .success;
}

pub fn ghostty_vt_osc_free(parser: GhosttyOscParser) callconv(.c) void {
    // C-built parsers always have an associated allocator.
    const alloc = parser.alloc.?;
    parser.deinit();
    alloc.destroy(parser);
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
