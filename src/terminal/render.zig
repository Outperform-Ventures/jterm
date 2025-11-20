const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fastmem = @import("../fastmem.zig");
const color = @import("color.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const page = @import("page.zig");
const Pin = @import("PageList.zig").Pin;
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Style = @import("style.zig").Style;
const Terminal = @import("Terminal.zig");

// TODO:
// - tests for cursor state
// - tests for dirty state
// - tests for colors
// - tests for linkCells

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

    /// The color state for the terminal.
    colors: Colors,

    /// Cursor state within the viewport.
    cursor: Cursor,

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

    /// The last viewport pin used to generate this state. This is NOT
    /// a tracked pin and is generally NOT safe to read other than the direct
    /// values for comparison.
    viewport_pin: ?Pin = null,

    /// Initial state.
    pub const empty: RenderState = .{
        .rows = 0,
        .cols = 0,
        .viewport_is_bottom = false,
        .colors = .{
            .background = .{},
            .foreground = .{},
            .cursor = null,
            .palette = color.default,
        },
        .cursor = .{
            .active = .{ .x = 0, .y = 0 },
            .viewport = null,
            .cell = .{},
            .style = undefined,
        },
        .row_data = .empty,
        .redraw = false,
        .screen = .primary,
    };

    /// The color state for the terminal.
    ///
    /// The background/foreground will be reversed if the terminal reverse
    /// color mode is on! You do not need to handle that manually!
    pub const Colors = struct {
        background: color.RGB,
        foreground: color.RGB,
        cursor: ?color.RGB,
        palette: color.Palette,
    };

    pub const Cursor = struct {
        /// The x/y position of the cursor within the active area.
        active: point.Coordinate,

        /// The x/y position of the cursor within the viewport. This
        /// may be null if the cursor is not visible within the viewport.
        viewport: ?Viewport,

        /// The cell data for the cursor position. Managed memory is not
        /// safe to access from this.
        cell: page.Cell,

        /// The style, always valid even if the cell is default style.
        style: Style,

        pub const Viewport = struct {
            /// The x/y position of the cursor within the viewport.
            x: size.CellCountInt,
            y: size.CellCountInt,

            /// Whether the cursor is part of a wide character and
            /// on the tail of it. If so, some renderers may use this
            /// to move the cursor back one.
            wide_tail: bool,
        };
    };

    /// A row within the viewport.
    pub const Row = struct {
        /// Arena used for any heap allocations for cell contents
        /// in this row. Importantly, this is NOT used for the MultiArrayList
        /// itself. We do this on purpose so that we can easily clear rows,
        /// but retain cached MultiArrayList capacities since grid sizes don't
        /// change often.
        arena: ArenaAllocator.State,

        /// The page pin. This is not safe to read unless you can guarantee
        /// the terminal state hasn't changed since the last `update` call.
        pin: Pin,

        /// Raw row data.
        raw: page.Row,

        /// The cells in this row. Guaranteed to be `cols` length.
        cells: std.MultiArrayList(Cell),

        /// A dirty flag that can be used by the renderer to track
        /// its own draw state. `update` will mark this true whenever
        /// this row is changed, too.
        dirty: bool,

        /// The x range of the selection within this row.
        selection: ?[2]size.CellCountInt,
    };

    pub const Cell = struct {
        /// Always set, this is the raw copied cell data from page.Cell.
        /// The managed memory (hyperlinks, graphames, etc.) is NOT safe
        /// to access from here. It is duplicated into the other fields if
        /// it exists.
        raw: page.Cell,

        /// Grapheme data for the cell. This is undefined unless the
        /// raw cell's content_tag is `codepoint_grapheme`.
        grapheme: []const u21,

        /// The style data for the cell. This is undefined unless
        /// the style_id is non-default on raw.
        style: Style,
    };

    pub fn deinit(self: *RenderState, alloc: Allocator) void {
        for (
            self.row_data.items(.arena),
            self.row_data.items(.cells),
        ) |state, *cells| {
            var arena: ArenaAllocator = state.promote(alloc);
            arena.deinit();
            cells.deinit(alloc);
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
        const viewport_pin = s.pages.getTopLeft(.viewport);
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

            // If our viewport pin changed, we do a full rebuild.
            if (self.viewport_pin) |old| {
                if (!old.eql(viewport_pin)) break :redraw true;
            }

            break :redraw false;
        };

        // Full redraw resets our state completely.
        if (redraw) {
            self.screen = t.screens.active_key;
            self.redraw = true;

            // Note: we don't clear any row_data here because our rebuild
            // below is going to do that for us.
        }

        // Always set our cheap fields, its more expensive to compare
        self.rows = s.pages.rows;
        self.cols = s.pages.cols;
        self.viewport_is_bottom = s.viewportIsBottom();
        self.viewport_pin = viewport_pin;
        self.cursor.active = .{ .x = s.cursor.x, .y = s.cursor.y };
        self.cursor.cell = s.cursor.page_cell.*;
        self.cursor.style = s.cursor.page_pin.style(s.cursor.page_cell);

        // Always reset the cursor viewport position. In the future we can
        // probably cache this by comparing the cursor pin and viewport pin
        // but may not be worth it.
        self.cursor.viewport = null;

        // Colors.
        self.colors.cursor = t.colors.cursor.get();
        self.colors.palette = t.colors.palette.current;
        bg_fg: {
            // Background/foreground can be unset initially which would
            // depend on "default" background/foreground. The expected use
            // case of Terminal is that the caller set their own configured
            // defaults on load so this doesn't happen.
            const bg = t.colors.background.get() orelse break :bg_fg;
            const fg = t.colors.foreground.get() orelse break :bg_fg;
            if (t.modes.get(.reverse_colors)) {
                self.colors.background = fg;
                self.colors.foreground = bg;
            } else {
                self.colors.background = bg;
                self.colors.foreground = fg;
            }
        }

        // Ensure our row length is exactly our height, freeing or allocating
        // data as necessary. In most cases we'll have a perfectly matching
        // size.
        if (self.row_data.len != self.rows) {
            @branchHint(.unlikely);

            if (self.row_data.len < self.rows) {
                // Resize our rows to the desired length, marking any added
                // values undefined.
                const old_len = self.row_data.len;
                try self.row_data.resize(alloc, self.rows);

                // Initialize all our values. Its faster to use slice() + set()
                // because appendAssumeCapacity does this multiple times.
                var row_data = self.row_data.slice();
                for (old_len..self.rows) |y| {
                    row_data.set(y, .{
                        .arena = .{},
                        .pin = undefined,
                        .raw = undefined,
                        .cells = .empty,
                        .dirty = true,
                        .selection = null,
                    });
                }
            } else {
                const row_data = self.row_data.slice();
                for (
                    row_data.items(.arena)[self.rows..],
                    row_data.items(.cells)[self.rows..],
                ) |state, *cell| {
                    var arena: ArenaAllocator = state.promote(alloc);
                    arena.deinit();
                    cell.deinit(alloc);
                }
                self.row_data.shrinkRetainingCapacity(self.rows);
            }
        }

        // Break down our row data
        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_pins = row_data.items(.pin);
        const row_raws = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_dirties = row_data.items(.dirty);

        // Track the last page that we know was dirty. This lets us
        // more quickly do the full-page dirty check.
        var last_dirty_page: ?*page.Page = null;

        // Go through and setup our rows.
        var row_it = s.pages.rowIterator(
            .right_down,
            .{ .viewport = .{} },
            null,
        );
        var y: size.CellCountInt = 0;
        while (row_it.next()) |row_pin| : (y = y + 1) {
            // Find our cursor if we haven't found it yet. We do this even
            // if the row is not dirty because the cursor is unrelated.
            if (self.cursor.viewport == null and
                row_pin.node == s.cursor.page_pin.node and
                row_pin.y == s.cursor.page_pin.y)
            {
                self.cursor.viewport = .{
                    .y = y,
                    .x = s.cursor.x,

                    // Future: we should use our own state here to look this
                    // up rather than calling this.
                    .wide_tail = if (s.cursor.x > 0)
                        s.cursorCellLeft(1).wide == .wide
                    else
                        false,
                };
            }

            // Store our pin. We have to store these even if we're not dirty
            // because dirty is only a renderer optimization. It doesn't
            // apply to memory movement. This will let us remap any cell
            // pins back to an exact entry in our RenderState.
            row_pins[y] = row_pin;

            // Get all our cells in the page.
            const p: *page.Page = &row_pin.node.data;
            const page_rac = row_pin.rowAndCell();

            dirty: {
                // If we're redrawing then we're definitely dirty.
                if (redraw) break :dirty;

                // If our page is the same as last time then its dirty.
                if (p == last_dirty_page) break :dirty;
                if (p.dirty) {
                    // If this page is dirty then clear the dirty flag
                    // of the last page and then store this one. This benchmarks
                    // faster than iterating pages again later.
                    if (last_dirty_page) |last_p| last_p.dirty = false;
                    last_dirty_page = p;
                }

                // If our row is dirty then we're dirty.
                if (page_rac.row.dirty) break :dirty;

                // Not dirty!
                continue;
            }

            // Clear our row dirty, we'll clear our page dirty later.
            // We can't clear it now because we have more rows to go through.
            page_rac.row.dirty = false;

            // Promote our arena. State is copied by value so we need to
            // restore it on all exit paths so we don't leak memory.
            var arena = row_arenas[y].promote(alloc);
            defer row_arenas[y] = arena.state;

            // Reset our cells if we're rebuilding this row.
            if (row_cells[y].len > 0) {
                _ = arena.reset(.retain_capacity);
                row_cells[y].clearRetainingCapacity();
            }
            row_dirties[y] = true;

            // Get all our cells in the page.
            const page_cells: []const page.Cell = p.getCells(page_rac.row);
            assert(page_cells.len == self.cols);

            // Copy our raw row data
            row_raws[y] = page_rac.row.*;

            // Note: our cells MultiArrayList uses our general allocator.
            // We do this on purpose because as rows become dirty, we do
            // not want to reallocate space for cells (which are large). This
            // was a source of huge slowdown.
            //
            // Our per-row arena is only used for temporary allocations
            // pertaining to cells directly (e.g. graphemes, hyperlinks).
            const cells: *std.MultiArrayList(Cell) = &row_cells[y];
            try cells.resize(alloc, self.cols);

            // We always copy our raw cell data. In the case we have no
            // managed memory, we can skip setting any other fields.
            //
            // This is an important optimization. For plain-text screens
            // this ends up being something around 300% faster based on
            // the `screen-clone` benchmark.
            const cells_slice = cells.slice();
            fastmem.copy(
                page.Cell,
                cells_slice.items(.raw),
                page_cells,
            );
            if (!page_rac.row.managedMemory()) continue;

            const arena_alloc = arena.allocator();
            const cells_grapheme = cells_slice.items(.grapheme);
            const cells_style = cells_slice.items(.style);
            for (page_cells, 0..) |*page_cell, x| {
                // Append assuming its a single-codepoint, styled cell
                // (most common by far).
                if (page_cell.style_id > 0) cells_style[x] = p.styles.get(
                    p.memory,
                    page_cell.style_id,
                ).*;

                // Switch on our content tag to handle less likely cases.
                switch (page_cell.content_tag) {
                    .codepoint => {
                        @branchHint(.likely);
                        // Primary codepoint goes into `raw` field.
                    },

                    // If we have a multi-codepoint grapheme, look it up and
                    // set our content type.
                    .codepoint_grapheme => {
                        @branchHint(.unlikely);
                        cells_grapheme[x] = try arena_alloc.dupe(
                            u21,
                            p.lookupGrapheme(page_cell) orelse &.{},
                        );
                    },

                    .bg_color_rgb => {
                        @branchHint(.unlikely);
                        cells_style[x] = .{ .bg_color = .{ .rgb = .{
                            .r = page_cell.content.color_rgb.r,
                            .g = page_cell.content.color_rgb.g,
                            .b = page_cell.content.color_rgb.b,
                        } } };
                    },

                    .bg_color_palette => {
                        @branchHint(.unlikely);
                        cells_style[x] = .{ .bg_color = .{
                            .palette = page_cell.content.color_palette,
                        } };
                    },
                }
            }
        }
        assert(y == self.rows);

        // If our screen has a selection, then mark the rows with the
        // selection.
        if (s.selection) |*sel| {
            @branchHint(.unlikely);

            // TODO:
            // - Mark the rows with selections
            // - Cache the selection (untracked) so we can avoid redoing
            // this expensive work every frame.

            // We need to determine if our selection is within the viewport.
            // The viewport is generally very small so the efficient way to
            // do this is to traverse the viewport pages and check for the
            // matching selection pages.

            _ = sel;
        }

        // Finalize our final dirty page
        if (last_dirty_page) |last_p| last_p.dirty = false;

        // Clear our dirty flags
        t.flags.dirty = .{};
        s.dirty = .{};
    }

    /// A set of coordinates representing cells.
    pub const CellSet = std.AutoArrayHashMapUnmanaged(point.Coordinate, void);

    /// Returns a map of the cells that match to an OSC8 hyperlink over the
    /// given point in the render state.
    ///
    /// IMPORTANT: The terminal must not have updated since the last call to
    /// `update`. If there is any chance the terminal has updated, the caller
    /// must first call `update` again to refresh the render state.
    ///
    /// For example, you may want to hold a lock for the duration of the
    /// update and hyperlink lookup to ensure no updates happen in between.
    pub fn linkCells(
        self: *const RenderState,
        alloc: Allocator,
        viewport_point: point.Coordinate,
    ) Allocator.Error!CellSet {
        var result: CellSet = .empty;
        errdefer result.deinit(alloc);

        const row_slice = self.row_data.slice();
        const row_pins = row_slice.items(.pin);
        const row_cells = row_slice.items(.cells);

        // Grab our link ID
        const link_page: *page.Page = &row_pins[viewport_point.y].node.data;
        const link = link: {
            const rac = link_page.getRowAndCell(
                viewport_point.x,
                viewport_point.y,
            );

            // The likely scenario is that our mouse isn't even over a link.
            if (!rac.cell.hyperlink) {
                @branchHint(.likely);
                return result;
            }

            const link_id = link_page.lookupHyperlink(rac.cell) orelse
                return result;
            break :link link_page.hyperlink_set.get(
                link_page.memory,
                link_id,
            );
        };

        for (
            0..,
            row_pins,
            row_cells,
        ) |y, pin, cells| {
            for (0.., cells.items(.raw)) |x, cell| {
                if (!cell.hyperlink) continue;

                const other_page: *page.Page = &pin.node.data;
                const other = link: {
                    const rac = other_page.getRowAndCell(x, y);
                    const link_id = other_page.lookupHyperlink(rac.cell) orelse continue;
                    break :link other_page.hyperlink_set.get(
                        other_page.memory,
                        link_id,
                    );
                };

                if (link.eql(
                    link_page.memory,
                    other,
                    other_page.memory,
                )) try result.put(alloc, .{
                    .y = @intCast(y),
                    .x = @intCast(x),
                }, {});
            }
        }

        return result;
    }
};

test "styled" {
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

    // Row zero should contain our text
    try testing.expectEqual('A', cells[0].get(0).raw.codepoint());
    try testing.expectEqual('B', cells[0].get(1).raw.codepoint());
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual('D', cells[0].get(3).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(4).raw.codepoint());
}

test "styled text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("\x1b[1mA"); // Bold
    try s.nextSlice("\x1b[0;3mB"); // Italic
    try s.nextSlice("\x1b[0;4mC"); // Underline

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

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual('B', cell.raw.codepoint());
        try testing.expect(!cell.style.flags.bold);
        try testing.expect(cell.style.flags.italic);
    }
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(3).raw.codepoint());
}

test "grapheme" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("A");
    try s.nextSlice("👨‍"); // this has a ZWJ

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

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual(0x1F468, cell.raw.codepoint());
        try testing.expectEqual(.wide, cell.raw.wide);
        try testing.expectEqualSlices(u21, &.{0x200D}, cell.grapheme);
    }
    {
        const cell = cells[0].get(2);
        try testing.expectEqual(0, cell.raw.codepoint());
        try testing.expectEqual(.spacer_tail, cell.raw.wide);
    }
}
