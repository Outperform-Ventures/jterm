const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const size = @import("../size.zig");
const PageList = @import("../PageList.zig");
const Selection = @import("../Selection.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const Terminal = @import("../Terminal.zig");

/// Searches for a substring within the active area of a PageList.
///
/// The distinction for "active area" is important because it is the
/// only part of a PageList that is mutable. Therefore, its the only part
/// of the terminal that needs to be repeatedly searched as the contents
/// change.
///
/// This struct specializes in searching only within that active area,
/// and handling the active area moving as new lines are added to the bottom.
pub const ActiveSearch = struct {
    window: SlidingWindow,

    pub fn init(
        alloc: Allocator,
        needle: []const u8,
    ) Allocator.Error!ActiveSearch {
        // We just do a forward search since the active area is usually
        // pretty small so search results are instant anyways. This avoids
        // a small amount of work to reverse things.
        var window: SlidingWindow = try .init(alloc, .forward, needle);
        errdefer window.deinit();
        return .{ .window = window };
    }

    pub fn deinit(self: *ActiveSearch) void {
        self.window.deinit();
    }

    /// Update the active area to reflect the current state of the PageList.
    ///
    /// This doesn't do the search, it only copies the necessary data
    /// to perform the search later. This lets the caller hold the lock
    /// on the PageList for a minimal amount of time.
    ///
    /// This returns the first page (in reverse order) NOT searched by
    /// this active area. This is useful for callers that want to follow up
    /// with populating the scrollback searcher. The scrollback searcher
    /// should start searching from the returned page backwards.
    ///
    /// If the return value is null it means the active area covers the entire
    /// PageList, currently.
    pub fn update(
        self: *ActiveSearch,
        list: *const PageList,
    ) Allocator.Error!?*PageList.List.Node {
        // Clear our previous sliding window
        self.window.clearAndRetainCapacity();

        // First up, add enough pages to cover the active area.
        var rem: usize = list.rows;
        var node_ = list.pages.last;
        while (node_) |node| : (node_ = node.prev) {
            _ = try self.window.append(node);

            // If we reached our target amount, then this is the last
            // page that contains the active area. We go to the previous
            // page once more since its the first page of our required
            // overlap.
            if (rem <= node.data.size.rows) {
                node_ = node.prev;
                break;
            }

            rem -= node.data.size.rows;
        }

        // Next, add enough overlap to cover needle.len - 1 bytes (if it
        // exists) so we can cover the overlap.
        rem = self.window.needle.len - 1;
        while (node_) |node| : (node_ = node.prev) {
            const added = try self.window.append(node);
            if (added >= rem) {
                node_ = node.prev;
                break;
            }
            rem -= added;
        }

        // Return the first page NOT covered by the active area.
        return node_;
    }

    /// Find the next match for the needle in the active area. This returns
    /// null when there are no more matches.
    pub fn next(self: *ActiveSearch) ?Selection {
        return self.window.next();
    }
};

test "simple search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screen.pages);

    {
        const sel = search.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, t.screen.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, t.screen.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = search.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, t.screen.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 2,
        } }, t.screen.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect(search.next() == null);
}

test "clear screen and search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screen.pages);

    try s.nextSlice("\x1b[2J"); // Clear screen
    try s.nextSlice("\x1b[H"); // Move cursor home
    try s.nextSlice("Buzz\r\nFizz\r\nBuzz");
    _ = try search.update(&t.screen.pages);

    {
        const sel = search.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screen.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screen.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect(search.next() == null);
}
