//! Search functionality for the terminal.
//!
//! At the time of writing this comment, this is a **work in progress**.
//!
//! Search at the time of writing is implemented using a simple
//! boyer-moore-horspool algorithm. The suboptimal part of the implementation
//! is that we need to encode each terminal page into a text buffer in order
//! to apply BMH to it. This is because the terminal page is not laid out
//! in a flat text form.
//!
//! To minimize memory usage, we use a sliding window to search for the
//! needle. The sliding window only keeps the minimum amount of page data
//! in memory to search for a needle (i.e. `needle.len - 1` bytes of overlap
//! between terminal pages).
//!
//! Future work:
//!
//!   - PageListSearch on a PageList concurrently with another thread
//!   - Handle pruned pages in a PageList to ensure we don't keep references
//!   - Repeat search a changing active area of the screen
//!   - Reverse search so that more recent matches are found first
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const terminal = @import("../main.zig");
const point = terminal.point;
const Page = terminal.Page;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;
const PageFormatter = @import("../formatter.zig").PageFormatter;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;

/// Searches for a term in a PageList structure.
///
/// At the time of writing, this does not support searching a pagelist
/// simultaneously as its being used by another thread. This will be resolved
/// in the future.
pub const PageListSearch = struct {
    /// The list we're searching.
    list: *PageList,

    /// The sliding window of page contents and nodes to search.
    window: SlidingWindow,

    /// Initialize the page list search. The needle is copied so it can
    /// be freed immediately.
    pub fn init(
        alloc: Allocator,
        list: *PageList,
        needle: []const u8,
    ) Allocator.Error!PageListSearch {
        var window: SlidingWindow = try .init(alloc, .forward, needle);
        errdefer window.deinit();

        return .{
            .list = list,
            .window = window,
        };
    }

    pub fn deinit(self: *PageListSearch) void {
        self.window.deinit();
    }

    /// Find the next match for the needle in the pagelist. This returns
    /// null when there are no more matches.
    pub fn next(self: *PageListSearch) Allocator.Error!?Selection {
        // Try to search for the needle in the window. If we find a match
        // then we can return that and we're done.
        if (self.window.next()) |sel| return sel;

        // Get our next node. If we have a value in our window then we
        // can determine the next node. If we don't, we've never setup the
        // window so we use our first node.
        var node_: ?*PageList.List.Node = if (self.window.meta.last()) |meta|
            meta.node.next
        else
            self.list.pages.first;

        // Add one pagelist node at a time, look for matches, and repeat
        // until we find a match or we reach the end of the pagelist.
        // This append then next pattern limits memory usage of the window.
        while (node_) |node| : (node_ = node.next) {
            try self.window.append(node);
            if (self.window.next()) |sel| return sel;
        }

        // We've reached the end of the pagelist, no matches.
        return null;
    }
};
