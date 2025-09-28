const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const osc = @import("../osc.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyOscParser
pub const Parser = ?*osc.Parser;

/// C: GhosttyOscCommand
pub const Command = ?*osc.Command;

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

pub fn reset(parser_: Parser) callconv(.c) void {
    parser_.?.reset();
}

pub fn next(parser_: Parser, byte: u8) callconv(.c) void {
    parser_.?.next(byte);
}

pub fn end(parser_: Parser, terminator: u8) callconv(.c) Command {
    return parser_.?.end(terminator);
}

pub fn commandType(command_: Command) callconv(.c) osc.Command.Key {
    const command = command_ orelse return .invalid;
    return command.*;
}

test "alloc" {
    const testing = std.testing;
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    free(p);
}

test "command type null" {
    const testing = std.testing;
    try testing.expectEqual(.invalid, commandType(null));
}

test "command type" {
    const testing = std.testing;
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    next(p, '0');
    next(p, ';');
    next(p, 'a');
    const cmd = end(p, 0);
    try testing.expectEqual(.change_window_title, commandType(cmd));
}
