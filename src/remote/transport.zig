const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

pub const Error = error{
    InvalidTarget,
    EmptyResponse,
    ResponseTooLarge,
};

const max_response_size = 1024 * 1024;

/// Convert a `--to` target string into a Unix socket path.
pub fn unixPathFromTarget(target: []const u8) Error![]const u8 {
    const prefix = "unix:";
    if (!std.mem.startsWith(u8, target, prefix)) return error.InvalidTarget;

    const path = target[prefix.len..];
    if (path.len == 0) return error.InvalidTarget;

    return path;
}

/// Send a single JSON request to a unix socket and read one newline-delimited response.
pub fn request(
    alloc: Allocator,
    target: []const u8,
    request_json: []const u8,
) ![]u8 {
    const path = try unixPathFromTarget(target);
    var stream = try std.net.connectUnixSocket(path);
    defer stream.close();

    const framed_request = try protocol.wrapFrame(alloc, request_json);
    defer alloc.free(framed_request);
    try stream.writeAll(framed_request);

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(alloc);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;

        const chunk = buf[0..n];
        try response.appendSlice(alloc, chunk);

        if (std.mem.startsWith(u8, response.items, protocol.dcs_prefix)) {
            if (std.mem.indexOf(u8, response.items, protocol.dcs_suffix) != null) break;
        } else if (std.mem.indexOfScalar(u8, response.items, '\n') != null) {
            break;
        }

        if (response.items.len > max_response_size) {
            return error.ResponseTooLarge;
        }
    }

    if (response.items.len == 0) return error.EmptyResponse;
    if (std.mem.startsWith(u8, response.items, protocol.dcs_prefix)) {
        const unwrapped = protocol.unwrapFrame(response.items) catch return error.EmptyResponse;
        return try alloc.dupe(u8, unwrapped);
    }

    if (std.mem.indexOfScalar(u8, response.items, '\n')) |idx| {
        return try alloc.dupe(u8, response.items[0..idx]);
    }

    return response.toOwnedSlice(alloc);
}

test "unixPathFromTarget parses unix prefix" {
    const testing = std.testing;

    const path = try unixPathFromTarget("unix:/tmp/jterm.sock");
    try testing.expectEqualStrings("/tmp/jterm.sock", path);
}

test "unixPathFromTarget rejects invalid target" {
    const testing = std.testing;

    try testing.expectError(error.InvalidTarget, unixPathFromTarget("tcp:127.0.0.1:22"));
    try testing.expectError(error.InvalidTarget, unixPathFromTarget("unix:"));
}
