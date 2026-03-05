const std = @import("std");
const terminal = @import("../terminal/main.zig");
const log = std.log.scoped(.renderer_cursor);

var cursor_debug_enabled_cache: ?bool = null;

/// Available cursor styles for drawing that renderers must support.
/// This is a superset of terminal cursor styles since the renderer supports
/// some additional cursor states such as the hollow block.
pub const Style = enum {
    // Typical cursor input styles
    block,
    block_hollow,
    bar,
    underline,

    // Special cursor styles
    lock,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(term: terminal.CursorStyle) ?Style {
        return switch (term) {
            .bar => .bar,
            // jTerm policy: always use a thin caret style, never a block cursor.
            .block => .bar,
            .block_hollow => .bar,
            .underline => .underline,
        };
    }
};

pub const StyleOptions = struct {
    preedit: bool = false,
    focused: bool = false,
    blink_visible: bool = false,
};

fn cursorDebugEnabled() bool {
    if (cursor_debug_enabled_cache) |enabled| return enabled;

    const enabled = if (std.posix.getenv("JTERM_COMPOSE_CURSOR_DEBUG")) |value| enabled: {
        const raw: []const u8 = value;
        if (raw.len == 0) break :enabled false;
        if (std.mem.eql(u8, raw, "0")) break :enabled false;
        if (std.ascii.eqlIgnoreCase(raw, "false")) break :enabled false;
        if (std.ascii.eqlIgnoreCase(raw, "off")) break :enabled false;
        if (std.ascii.eqlIgnoreCase(raw, "no")) break :enabled false;
        break :enabled true;
    } else false;

    cursor_debug_enabled_cache = enabled;
    return enabled;
}

fn styleName(style_: ?Style) []const u8 {
    return if (style_) |s| @tagName(s) else "none";
}

fn debugReturn(
    state: *const terminal.RenderState,
    opts: StyleOptions,
    result: ?Style,
    reason: []const u8,
) ?Style {
    if (cursorDebugEnabled()) {
        log.info(
            "cursor decision reason={s} result={s} visible={} viewport={} preedit={} focused={} blink_visible={} blinking={} password={} visual={s}",
            .{
                reason,
                styleName(result),
                state.cursor.visible,
                state.cursor.viewport != null,
                opts.preedit,
                opts.focused,
                opts.blink_visible,
                state.cursor.blinking,
                state.cursor.password_input,
                @tagName(state.cursor.visual_style),
            },
        );
    }
    return result;
}

/// Returns the cursor style to use for the current render state or null
/// if a cursor should not be rendered at all.
pub fn style(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) ?Style {
    // Note the order of conditionals below is important. It represents
    // a priority system of how we determine what state overrides cursor
    // visibility and style.

    // The cursor must be visible in the viewport to be rendered.
    if (state.cursor.viewport == null) return debugReturn(state, opts, null, "no-viewport");

    // If the cursor is explicitly not visible by terminal mode, we don't render.
    if (!state.cursor.visible) return debugReturn(state, opts, null, "hidden-by-mode");

    // During preedit we still force a visible cursor, but keep it thin.
    // Visibility checks must happen first so host-side cursor suppression
    // (for overlays like native compose) always wins.
    if (opts.preedit) return debugReturn(state, opts, .bar, "preedit");

    // If we're at a password input its always a lock.
    if (state.cursor.password_input) return debugReturn(state, opts, .lock, "password");

    // If we're not focused, keep the cursor visible but thin.
    if (!opts.focused) return debugReturn(state, opts, .bar, "unfocused");

    // If the cursor is blinking and our blink state is not visible,
    // then we don't show the cursor.
    if (state.cursor.blinking and !opts.blink_visible) {
        return debugReturn(state, opts, null, "blink-hidden");
    }

    // Otherwise, we use whatever style the terminal wants.
    return debugReturn(
        state,
        opts,
        .fromTerminal(state.cursor.visual_style),
        "terminal-style",
    );
}

test "cursor: default uses configured style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term: terminal.Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = false }) == null);
}

test "cursor: blinking disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == .bar);
}

test "cursor: explicitly not visible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, false);
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == null);
}

test "cursor: preedit keeps a thin visible cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == .bar);

    // If we're scrolled though, then we don't show the cursor.
    for (0..100) |_| try term.index();
    term.scrollViewport(.{ .top = {} });
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == null);
}
