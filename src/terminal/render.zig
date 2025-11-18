const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const size = @import("size.zig");
const page = @import("page.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Style = @import("style.zig").Style;
const Terminal = @import("Terminal.zig");

// Developer note: this is in src/terminal and not src/renderer because
// the goal is that this remains generic to multiple renderers. This can
// aid specifically with libghostty-vt with converting terminal state to
// a renderable form.

/// Contains the state required to render the screen, including optimizing
/// for repeated render calls and only rendering dirty regions.
///
/// Previously, our renderer would use `clone` to clone the screen within
/// the viewport to perform rendering. This worked well enough that we kept
/// it all the way up through the Ghostty 1.2.x series, but the clone time
/// was repeatedly a bottleneck blocking IO.
///
/// Rather than a generic clone that tries to clone all screen state per call
/// (within a region), a stateful approach that optimizes for only what a
/// renderer needs to do makes more sense.
pub const RenderState = struct {
    /// The current screen dimensions. It is possible that these don't match
    /// the renderer's current dimensions in grid cells because resizing
    /// can happen asynchronously. For example, for Metal, our NSView resizes
    /// at a different time than when our internal terminal state resizes.
    /// This can lead to a one or two frame mismatch a renderer needs to
    /// handle.
    ///
    /// The viewport is always exactly equal to the active area size so this
    /// is also the viewport size.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    /// The viewport is at the bottom of the terminal, viewing the active
    /// area and scrolling with new output.
    viewport_is_bottom: bool,

    /// The rows (y=0 is top) of the viewport. Guaranteed to be `rows` length.
    ///
    /// This is a MultiArrayList because only the update cares about
    /// the allocators. Callers care about all the other properties, and
    /// this better optimizes cache locality for read access for those
    /// use cases.
    row_data: std.MultiArrayList(Row),

    /// This is set to true if the terminal state has changed in a way
    /// that the renderer should do a full redraw of the grid. The renderer
    /// should se this to false when it has done so. `update` will only
    /// ever tick this to true.
    redraw: bool,

    /// The screen type that this state represents. This is used primarily
    /// to detect changes.
    screen: ScreenSet.Key,

    /// Initial state.
    pub const empty: RenderState = .{
        .rows = 0,
        .cols = 0,
        .viewport_is_bottom = false,
        .row_data = .empty,
        .redraw = false,
        .screen = .primary,
    };

    /// A row within the viewport.
    pub const Row = struct {
        /// Arena used for any heap allocations for this row,
        arena: ArenaAllocator.State,

        /// The cells in this row. Guaranteed to be `cols` length.
        cells: std.MultiArrayList(Cell),

        /// A dirty flag that can be used by the renderer to track
        /// its own draw state. `update` will mark this true whenever
        /// this row is changed, too.
        dirty: bool,
    };

    pub const Cell = struct {
        content: Content,
        wide: page.Cell.Wide,
        style: Style,

        pub const Content = union(enum) {
            empty,
            single: u21,
            slice: []const u21,
        };
    };

    pub fn deinit(self: *RenderState, alloc: Allocator) void {
        for (self.row_data.items(.arena)) |state| {
            var arena: ArenaAllocator = state.promote(alloc);
            arena.deinit();
        }
        self.row_data.deinit(alloc);
    }

    /// Update the render state to the latest terminal state.
    ///
    /// This will reset the terminal dirty state since it is consumed
    /// by this render state update.
    pub fn update(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        const s: *Screen = t.screens.active;
        const redraw = redraw: {
            // If our screen key changed, we need to do a full rebuild
            // because our render state is viewport-specific.
            if (t.screens.active_key != self.screen) break :redraw true;

            // If our terminal is dirty at all, we do a full rebuild. These
            // dirty values are full-terminal dirty values.
            {
                const Int = @typeInfo(Terminal.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.flags.dirty);
                if (v > 0) break :redraw true;
            }

            // If our screen is dirty at all, we do a full rebuild. This is
            // a full screen dirty tracker.
            {
                const Int = @typeInfo(Screen.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.screens.active.dirty);
                if (v > 0) break :redraw true;
            }

            // If our dimensions changed, we do a full rebuild.
            if (self.rows != s.pages.rows or
                self.cols != s.pages.cols)
            {
                break :redraw true;
            }

            break :redraw false;
        };

        // Full redraw resets our state completely.
        if (redraw) {
            self.* = .empty;
            self.screen = t.screens.active_key;
            self.redraw = true;
        }

        // Always set our cheap fields, its more expensive to compare
        self.rows = s.pages.rows;
        self.cols = s.pages.cols;
        self.viewport_is_bottom = s.viewportIsBottom();

        // Ensure our row length is exactly our height, freeing or allocating
        // data as necessary.
        if (self.row_data.len <= self.rows) {
            @branchHint(.likely);
            try self.row_data.ensureTotalCapacity(alloc, self.rows);
            for (self.row_data.len..self.rows) |_| {
                self.row_data.appendAssumeCapacity(.{
                    .arena = .{},
                    .cells = .empty,
                    .dirty = true,
                });
            }
        } else {
            const arenas = self.row_data.items(.arena);
            for (arenas[self.rows..]) |state| {
                var arena: ArenaAllocator = state.promote(alloc);
                arena.deinit();
            }
            self.row_data.shrinkRetainingCapacity(self.rows);
        }

        // Break down our row data
        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_cells = row_data.items(.cells);
        const row_dirties = row_data.items(.dirty);

        // Go through and setup our rows.
        var row_it = s.pages.rowIterator(
            .left_up,
            .{ .viewport = .{} },
            null,
        );
        var y: size.CellCountInt = 0;
        while (row_it.next()) |row_pin| : (y = y + 1) {
            // If the row isn't dirty then we assume it is unchanged.
            if (!redraw and !row_pin.isDirty()) continue;

            // Promote our arena. State is copied by value so we need to
            // restore it on all exit paths so we don't leak memory.
            var arena = row_arenas[y].promote(alloc);
            defer row_arenas[y] = arena.state;
            const arena_alloc = arena.allocator();

            // Reset our cells if we're rebuilding this row.
            if (row_cells[y].len > 0) {
                _ = arena.reset(.retain_capacity);
                row_cells[y] = .empty;
            }
            row_dirties[y] = true;

            // Get all our cells in the page.
            const p: *page.Page = &row_pin.node.data;
            const page_rac = row_pin.rowAndCell();
            const page_cells: []const page.Cell = p.getCells(page_rac.row);
            assert(page_cells.len == self.cols);

            const cells: *std.MultiArrayList(Cell) = &row_cells[y];
            try cells.ensureTotalCapacity(arena_alloc, self.cols);
            for (page_cells) |*page_cell| {
                // Append assuming its a single-codepoint, styled cell
                // (most common by far).
                const idx = cells.len;
                cells.appendAssumeCapacity(.{
                    .content = .empty, // Filled in below
                    .wide = page_cell.wide,
                    .style = if (page_cell.style_id > 0) p.styles.get(
                        p.memory,
                        page_cell.style_id,
                    ).* else .{},
                });

                // Switch on our content tag to handle less likely cases.
                switch (page_cell.content_tag) {
                    .codepoint => {
                        @branchHint(.likely);

                        // It is possible for our codepoint to be zero. If
                        // that is the case, we set the codepoint to empty.
                        const cp = page_cell.content.codepoint;
                        var content = cells.items(.content);
                        content[idx] = if (cp == 0) zero: {
                            // Spacers are meaningful and not actually empty
                            // so we only set empty for truly empty cells.
                            if (page_cell.wide == .narrow) {
                                @branchHint(.likely);
                                break :zero .empty;
                            }

                            break :zero .{ .single = ' ' };
                        } else .{
                            .single = cp,
                        };
                    },

                    // If we have a multi-codepoint grapheme, look it up and
                    // set our content type.
                    .codepoint_grapheme => grapheme: {
                        @branchHint(.unlikely);

                        const extra = p.lookupGrapheme(page_cell) orelse break :grapheme;
                        var cps = try arena_alloc.alloc(u21, extra.len + 1);
                        cps[0] = page_cell.content.codepoint;
                        @memcpy(cps[1..], extra);

                        var content = cells.items(.content);
                        content[idx] = .{ .slice = cps };
                    },

                    .bg_color_rgb => {
                        @branchHint(.unlikely);

                        var content = cells.items(.style);
                        content[idx] = .{ .bg_color = .{ .rgb = .{
                            .r = page_cell.content.color_rgb.r,
                            .g = page_cell.content.color_rgb.g,
                            .b = page_cell.content.color_rgb.b,
                        } } };
                    },

                    .bg_color_palette => {
                        @branchHint(.unlikely);

                        var content = cells.items(.style);
                        content[idx] = .{ .bg_color = .{
                            .palette = page_cell.content.color_palette,
                        } };
                    },
                }
            }
        }
        assert(y == self.rows);

        // Clear our dirty flags
        t.flags.dirty = .{};
        s.dirty = .{};
    }
};

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    // This fills the screen up
    try t.decaln();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
}

test "basic text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("ABCD");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);
}
