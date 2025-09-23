const std = @import("std");
const Properties = @import("Properties.zig");
const lut = @import("lut.zig");

/// The lookup tables for Ghostty.
pub const table = table: {
    // This is only available after running a generator as part of the Ghostty
    // build.zig process, but due to Zig's lazy analysis we can still reference
    // it here.
    //
    // An example process is the `main` in `props_uucode.zig`
    const generated = @import("unicode_tables").Tables(Properties);
    const Tables = lut.Tables(Properties);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};

test "unicode props: tables match uucode" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const uucode = @import("uucode");
    const testing = std.testing;

    const min = 0xFF + 1; // start outside ascii
    const max = std.math.maxInt(u21) + 1;
    for (min..max) |cp| {
        const t = table.get(@intCast(cp));
        const uu = if (cp > uucode.config.max_code_point)
            1
        else
            uucode.get(.width, @intCast(cp));
        if (t.width != uu) {
            std.log.warn("mismatch cp=U+{x} t={} uu={}", .{ cp, t.width, uu });
            try testing.expect(false);
        }
    }
}

test "unicode props: tables match ziglyph" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const ziglyph = @import("ziglyph");
    const testing = std.testing;

    const min = 0xFF + 1; // start outside ascii
    const max = std.math.maxInt(u21) + 1;
    for (min..max) |cp| {
        const t = table.get(@intCast(cp));
        const zg = @min(2, @max(0, ziglyph.display_width.codePointWidth(@intCast(cp), .half)));
        if (t.width != zg) {

            // Known exceptions
            if (cp == 0x0897) continue; // non-spacing mark (t = 0)
            if (cp == 0x2065) continue; // unassigned (t = 1)
            if (cp >= 0x2630 and cp <= 0x2637) continue; // east asian width is wide (t = 2)
            if (cp >= 0x268A and cp <= 0x268F) continue; // east asian width is wide (t = 2)
            if (cp >= 0x2FFC and cp <= 0x2FFF) continue; // east asian width is wide (t = 2)
            if (cp == 0x31E4 or cp == 0x31E5) continue; // east asian width is wide (t = 2)
            if (cp == 0x31EF) continue; // east asian width is wide (t = 2)
            if (cp >= 0x4DC0 and cp <= 0x4DFF) continue; // east asian width is wide (t = 2)
            if (cp >= 0xFFF0 and cp <= 0xFFF8) continue; // unassigned (t = 1)
            if (cp >= 0xFFF0 and cp <= 0xFFF8) continue; // unassigned (t = 1)
            if (cp >= 0x10D69 and cp <= 0x10D6D) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0x10EFC and cp <= 0x10EFF) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0x113BB and cp <= 0x113C0) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113CE) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113D0) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113D2) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113E1) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113E2) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1171E) continue; // mark spacing combining (t = 1)
            if (cp == 0x11F5A) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1611E) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1611F) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0x16120 and cp <= 0x1612F) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0xE0000 and cp <= 0xE0FFF) continue; // ziglyph ignores these with 0, but many are unassigned (t = 1)
            if (cp == 0x18CFF) continue; // east asian width is wide (t = 2)
            if (cp >= 0x1D300 and cp <= 0x1D376) continue; // east asian width is wide (t = 2)
            if (cp == 0x1E5EE) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1E5EF) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1FA89) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FA8F) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FABE) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FAC6) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FADC) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FADF) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FAE9) continue; // east asian width is wide (t = 2)

            std.log.warn("mismatch cp=U+{x} t={} zg={}", .{ cp, t.width, zg });
            try testing.expect(false);
        }
    }
}
