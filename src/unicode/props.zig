const props = @This();
const std = @import("std");
const assert = std.debug.assert;
const uucode = @import("uucode");
const lut = @import("lut.zig");

/// The lookup tables for Ghostty.
pub const table = table: {
    const Props = uucode.PackedTypeOf("1");
    // This is only available after running main() below as part of the Ghostty
    // build.zig, but due to Zig's lazy analysis we can still reference it here.
    const generated = @import("unicode_tables").Tables(Props);
    const Tables = lut.Tables(Props);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};

/// Property set per codepoint that Ghostty cares about.
///
/// Adding to this lets you find new properties but also potentially makes
/// our lookup tables less efficient. Any changes to this should run the
/// benchmarks in src/bench to verify that we haven't regressed.
pub const Properties = struct {
    /// Codepoint width. We clamp to [0, 2] since Ghostty handles control
    /// characters and we max out at 2 for wide characters (i.e. 3-em dash
    /// becomes a 2-em dash).
    width: u2 = 0,

    /// Grapheme boundary class.
    grapheme_boundary_class: GraphemeBoundaryClass = .invalid,

    // Needed for lut.Generator
    pub fn eql(a: Properties, b: Properties) bool {
        return a.width == b.width and
            a.grapheme_boundary_class == b.grapheme_boundary_class;
    }

    // Needed for lut.Generator
    pub fn format(
        self: Properties,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;
        try std.fmt.format(writer,
            \\.{{
            \\    .width= {},
            \\    .grapheme_boundary_class= .{s},
            \\}}
        , .{
            self.width,
            @tagName(self.grapheme_boundary_class),
        });
    }
};

/// Possible grapheme boundary classes. This isn't an exhaustive list:
/// we omit control, CR, LF, etc. because in Ghostty's usage that are
/// impossible because they're handled by the terminal.
pub const GraphemeBoundaryClass = uucode.TypeOfX(.grapheme_boundary_class);

/// Gets the grapheme boundary class for a codepoint.
/// The use case for this is only in generating lookup tables.
fn computeGraphemeBoundaryClass(cp: u21) GraphemeBoundaryClass {
    if (cp > uucode.config.max_code_point) return .invalid;
    if (uucode.get(.is_emoji_modifier, cp)) return .emoji_modifier;
    if (uucode.get(.is_emoji_modifier_base, cp)) return .extended_pictographic_base;

    return switch (uucode.get(.grapheme_break, cp)) {
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

/// Returns true if this is an extended pictographic type. This
/// should be used instead of comparing the enum value directly
/// because we classify multiple.
pub fn isExtendedPictographic(self: GraphemeBoundaryClass) bool {
    return switch (self) {
        .extended_pictographic,
        .extended_pictographic_base,
        => true,

        else => false,
    };
}

pub fn get(cp: u21) Properties {
    const wcwidth = if (cp > uucode.config.max_code_point)
        0
    else
        uucode.get(.wcwidth, cp);

    return .{
        .width = @intCast(@min(2, @max(0, wcwidth))),
        .grapheme_boundary_class = computeGraphemeBoundaryClass(cp),
    };
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();
    _ = args_iter.skip(); // Skip program name

    const output_path = args_iter.next() orelse std.debug.panic("No output file arg for props exe!", .{});
    std.debug.print("Unicode props_table output_path = {s}\n", .{output_path});

    const gen: lut.Generator(
        Properties,
        struct {
            pub fn get(ctx: @This(), cp: u21) !Properties {
                _ = ctx;
                return props.get(cp);
            }

            pub fn eql(ctx: @This(), a: Properties, b: Properties) bool {
                _ = ctx;
                return a.eql(b);
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);
    var out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    const writer = out_file.writer();
    try t.writeZig(writer);

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });
}

// This is not very fast in debug modes, so its commented by default.
// IMPORTANT: UNCOMMENT THIS WHENEVER MAKING CODEPOINTWIDTH CHANGES.
// test "unicode props: tables match uucode" {
//     const testing = std.testing;
//
//     const min = 0xFF + 1; // start outside ascii
//     const max = std.math.maxInt(u21) + 1;
//     for (min..max) |cp| {
//         const t = table.get(@intCast(cp));
//         const uu = @min(2, @max(0, uucode.get(.wcwidth, @intCast(cp))));
//         if (t.width != uu) {
//             std.log.warn("mismatch cp=U+{x} t={} uucode={}", .{ cp, t, uu });
//             try testing.expect(false);
//         }
//     }
//}
