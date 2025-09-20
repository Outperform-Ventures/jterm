pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
pub const table = @import("props_table.zig").table;
pub const Properties = @import("Properties.zig");
pub const graphemeBreak = grapheme.graphemeBreak;
pub const GraphemeBreakState = grapheme.BreakState;

test {
    _ = @import("props_ziglyph.zig");
    _ = @import("symbols.zig");
    @import("std").testing.refAllDecls(@This());
}
