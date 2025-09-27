const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const osc = @import("../osc.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyOscParser
pub const Parser = ?*osc.Parser;

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Parser,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(osc.Parser) catch
        return .out_of_memory;
    ptr.* = .initAlloc(alloc);
    result.* = ptr;
    return .success;
}

pub fn free(parser_: Parser) callconv(.c) void {
    // C-built parsers always have an associated allocator.
    const parser = parser_ orelse return;
    const alloc = parser.alloc.?;
    parser.deinit();
    alloc.destroy(parser);
}

test "osc" {
    const testing = std.testing;
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    free(p);
}
