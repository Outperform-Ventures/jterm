const props = @This();
const std = @import("std");
const assert = std.debug.assert;
const ziglyph = @import("ziglyph");
const lut2 = @import("lut2.zig");

/// The lookup tables for Ghostty.
pub const table = table: {
    // This is only available after running main() below as part of the Ghostty
    // build.zig, but due to Zig's lazy analysis we can still reference it here.
    const generated = @import("symbols2_tables");
    break :table lut2.Tables{
        .min = generated.min,
        .max = generated.max,
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
    };
};

/// Returns true of the codepoint is a "symbol-like" character, which
/// for now we define as anything in a private use area and anything
/// in several unicode blocks:
/// - Dingbats
/// - Emoticons
/// - Miscellaneous Symbols
/// - Enclosed Alphanumerics
/// - Enclosed Alphanumeric Supplement
/// - Miscellaneous Symbols and Pictographs
/// - Transport and Map Symbols
///
/// In the future it may be prudent to expand this to encompass more
/// symbol-like characters, and/or exclude some PUA sections.
pub fn isSymbol(cp: u21) bool {
    return ziglyph.general_category.isPrivateUse(cp) or
        ziglyph.blocks.isDingbats(cp) or
        ziglyph.blocks.isEmoticons(cp) or
        ziglyph.blocks.isMiscellaneousSymbols(cp) or
        ziglyph.blocks.isEnclosedAlphanumerics(cp) or
        ziglyph.blocks.isEnclosedAlphanumericSupplement(cp) or
        ziglyph.blocks.isMiscellaneousSymbolsAndPictographs(cp) or
        ziglyph.blocks.isTransportAndMapSymbols(cp);
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const gen: lut2.Generator(
        struct {
            pub fn get(ctx: @This(), cp: u21) bool {
                _ = ctx;
                return isSymbol(cp);
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    try t.writeZig(std.io.getStdOut().writer());

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    // });
}

// This is not very fast in debug modes, so its commented by default.
// IMPORTANT: UNCOMMENT THIS WHENEVER MAKING CHANGES.
test "unicode symbols2: tables match ziglyph" {
    const testing = std.testing;

    for (0..std.math.maxInt(u21)) |cp| {
        const t1 = table.get(@intCast(cp));
        const zg = isSymbol(@intCast(cp));

        if (t1 != zg) {
            std.log.warn("mismatch cp=U+{x} t={} zg={}", .{ cp, t1, zg });
            try testing.expect(false);
        }
    }
}
