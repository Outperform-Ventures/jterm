const std = @import("std");
const lut = @import("lut.zig");

/// The lookup tables for Ghostty.
pub const table = table: {
    // This is only available after running a generator as part of the Ghostty
    // build.zig process, but due to Zig's lazy analysis we can still reference
    // it here.
    //
    // An example process is the `main` in `symbols_uucode.zig`
    const generated = @import("symbols_tables").Tables(bool);
    const Tables = lut.Tables(bool);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};

test "unicode symbols: tables match uucode" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const uucode = @import("uucode");
    const testing = std.testing;

    for (0..std.math.maxInt(u21)) |cp| {
        const t = table.get(@intCast(cp));
        const uu = if (cp > uucode.config.max_code_point)
            false
        else
            uucode.get(.is_symbol, @intCast(cp));

        if (t != uu) {
            std.log.warn("mismatch cp=U+{x} t={} uu={}", .{ cp, t, uu });
            try testing.expect(false);
        }
    }
}

test "unicode symbols: tables match ziglyph" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const ziglyph = @import("ziglyph");
    const testing = std.testing;

    for (0..std.math.maxInt(u21)) |cp_usize| {
        const cp: u21 = @intCast(cp_usize);
        const t = table.get(cp);
        const zg = ziglyph.general_category.isPrivateUse(cp) or
            ziglyph.blocks.isDingbats(cp) or
            ziglyph.blocks.isEmoticons(cp) or
            ziglyph.blocks.isMiscellaneousSymbols(cp) or
            ziglyph.blocks.isEnclosedAlphanumerics(cp) or
            ziglyph.blocks.isEnclosedAlphanumericSupplement(cp) or
            ziglyph.blocks.isMiscellaneousSymbolsAndPictographs(cp) or
            ziglyph.blocks.isTransportAndMapSymbols(cp);

        if (t != zg) {
            std.log.warn("mismatch cp=U+{x} t={} zg={}", .{ cp, t, zg });
            try testing.expect(false);
        }
    }
}
