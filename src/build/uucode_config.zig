const config = @import("config.zig");
const config_x = @import("config.x.zig");
const d = config.default;
const wcwidth = config_x.wcwidth;

pub const log_level = .debug;

fn computeWidth(cp: u21, data: anytype, backing: anytype, tracking: anytype) void {
    _ = cp;
    _ = backing;
    _ = tracking;
    if (data.wcwidth < 0) {
        data.width = 0;
    } else if (data.wcwidth > 2) {
        data.width = 2;
    } else {
        data.width = @intCast(data.wcwidth);
    }
}

const width = config.Extension{ .inputs = &.{"wcwidth"}, .compute = &computeWidth, .fields = &.{
    .{ .name = "width", .type = u2 },
} };

pub const GraphemeBoundaryClass = enum(u4) {
    invalid,
    L,
    V,
    T,
    LV,
    LVT,
    prepend,
    extend,
    zwj,
    spacing_mark,
    regional_indicator,
    extended_pictographic,
    extended_pictographic_base, // \p{Extended_Pictographic} & \p{Emoji_Modifier_Base}
    emoji_modifier, // \p{Emoji_Modifier}
};

fn computeGraphemeBoundaryClass(cp: u21, data: anytype, backing: anytype, tracking: anytype) void {
    _ = cp;
    _ = backing;
    _ = tracking;
    if (data.is_emoji_modifier) {
        data.grapheme_boundary_class = .emoji_modifier;
    } else if (data.is_emoji_modifier_base) {
        data.grapheme_boundary_class = .extended_pictographic_base;
    } else {
        data.grapheme_boundary_class = switch (data.grapheme_break) {
            .extended_pictographic => .extended_pictographic,
            .l => .L,
            .v => .V,
            .t => .T,
            .lv => .LV,
            .lvt => .LVT,
            .prepend => .prepend,
            .zwj => .zwj,
            .spacing_mark => .spacing_mark,
            .regional_indicator => .regional_indicator,

            .zwnj,
            .indic_conjunct_break_extend,
            .indic_conjunct_break_linker,
            => .extend,

            // This is obviously not INVALID invalid, there is SOME grapheme
            // boundary class for every codepoint. But we don't care about
            // anything that doesn't fit into the above categories.
            .other,
            .indic_conjunct_break_consonant,
            .cr,
            .lf,
            .control,
            => .invalid,
        };
    }
}

const grapheme_boundary_class = config.Extension{
    .inputs = &.{
        "grapheme_break",
        "is_emoji_modifier",
        "is_emoji_modifier_base",
    },
    .compute = &computeGraphemeBoundaryClass,
    .fields = &.{
        .{ .name = "grapheme_boundary_class", .type = GraphemeBoundaryClass },
    },
};

fn computeIsSymbol(cp: u21, data: anytype, backing: anytype, tracking: anytype) void {
    _ = cp;
    _ = backing;
    _ = tracking;
    const block = data.block;
    data.is_symbol = data.general_category == .other_private_use or
        block == .dingbats or
        block == .emoticons or
        block == .miscellaneous_symbols or
        block == .enclosed_alphanumerics or
        block == .enclosed_alphanumeric_supplement or
        block == .miscellaneous_symbols_and_pictographs or
        block == .transport_and_map_symbols;
}

const is_symbol = config.Extension{
    .inputs = &.{ "block", "general_category" },
    .compute = &computeIsSymbol,
    .fields = &.{
        .{ .name = "is_symbol", .type = bool },
    },
};

pub const tables = [_]config.Table{
    .{
        .extensions = &.{wcwidth},
        .fields = &.{
            wcwidth.field("wcwidth"),
            d.field("general_category"),
            d.field("block"),
            d.field("is_emoji_presentation"),
            d.field("case_folding_full"),
            // Alternative:
            // d.field("case_folding_simple"),
            d.field("is_emoji_modifier"),
            d.field("is_emoji_modifier_base"),
            d.field("grapheme_break"),
        },
    },
    .{
        .extensions = &.{ wcwidth, width, grapheme_boundary_class },
        .fields = &.{
            width.field("width"),
            grapheme_boundary_class.field("grapheme_boundary_class"),
        },
    },
    .{
        .extensions = &.{is_symbol},
        .fields = &.{
            is_symbol.field("is_symbol"),
        },
    },
};
