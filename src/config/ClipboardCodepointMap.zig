/// ClipboardCodepointMap is a map of codepoints to replacement values
/// for clipboard operations. When copying text to clipboard, matching
/// codepoints will be replaced with their mapped values.
const ClipboardCodepointMap = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Replacement = union(enum) {
    /// Replace with a single codepoint
    codepoint: u21,
    /// Replace with a UTF-8 string
    string: []const u8,
};

pub const Entry = struct {
    /// Unicode codepoint range. Asserts range[0] <= range[1].
    range: [2]u21,

    /// The replacement value for this range.
    replacement: Replacement,
};

/// The list of entries. We use a multiarraylist for cache-friendly lookups.
///
/// Note: we do a linear search because we expect to always have very
/// few entries, so the overhead of a binary search is not worth it.
list: std.MultiArrayList(Entry) = .{},

pub fn deinit(self: *ClipboardCodepointMap, alloc: Allocator) void {
    self.list.deinit(alloc);
}

/// Deep copy of the struct. The given allocator is expected to
/// be an arena allocator of some sort since the struct itself
/// doesn't support fine-grained deallocation of fields.
pub fn clone(self: *const ClipboardCodepointMap, alloc: Allocator) !ClipboardCodepointMap {
    var list = try self.list.clone(alloc);
    for (list.items(.replacement)) |*r| {
        switch (r.*) {
            .string => |s| r.string = try alloc.dupe(u8, s),
            .codepoint => {}, // no allocation needed
        }
    }

    return .{ .list = list };
}

/// Add an entry to the map.
///
/// For conflicting codepoints, entries added later take priority over
/// entries added earlier.
pub fn add(self: *ClipboardCodepointMap, alloc: Allocator, entry: Entry) !void {
    assert(entry.range[0] <= entry.range[1]);
    try self.list.append(alloc, entry);
}

/// Get a replacement for a codepoint.
pub fn get(self: *const ClipboardCodepointMap, cp: u21) ?Replacement {
    const items = self.list.items(.range);
    for (0..items.len) |forward_i| {
        const i = items.len - forward_i - 1;
        const range = items[i];
        if (range[0] <= cp and cp <= range[1]) {
            const replacements = self.list.items(.replacement);
            return replacements[i];
        }
    }

    return null;
}


test "clipboard codepoint map" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var m: ClipboardCodepointMap = .{};
    defer m.deinit(alloc);

    // Test no matches initially
    try testing.expect(m.get(1) == null);

    // Add exact range with codepoint replacement
    try m.add(alloc, .{
        .range = .{ 1, 1 },
        .replacement = .{ .codepoint = 65 }, // 'A'
    });
    {
        const replacement = m.get(1).?;
        try testing.expect(replacement == .codepoint);
        try testing.expectEqual(@as(u21, 65), replacement.codepoint);
    }

    // Later entry takes priority
    try m.add(alloc, .{
        .range = .{ 1, 2 },
        .replacement = .{ .string = "B" },
    });
    {
        const replacement = m.get(1).?;
        try testing.expect(replacement == .string);
        try testing.expectEqualStrings("B", replacement.string);
    }

    // Non-matching
    try testing.expect(m.get(0) == null);
    try testing.expect(m.get(3) == null);

    // Test range matching
    try m.add(alloc, .{
        .range = .{ 3, 5 },
        .replacement = .{ .string = "range" },
    });
    {
        const replacement = m.get(4).?;
        try testing.expectEqualStrings("range", replacement.string);
    }
    try testing.expect(m.get(6) == null);
}