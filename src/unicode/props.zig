//! Property set per codepoint that Ghostty cares about.
//!
//! Adding to this lets you find new properties but also potentially makes
//! our lookup tables less efficient. Any changes to this should run the
//! benchmarks in src/bench to verify that we haven't regressed.

const std = @import("std");
const uucode = @import("uucode");

pub const Properties = packed struct {
    /// Codepoint width. We clamp to [0, 2] since Ghostty handles control
    /// characters and we max out at 2 for wide characters (i.e. 3-em dash
    /// becomes a 2-em dash).
    width: u2 = 0,

    /// Grapheme break property.
    grapheme_break: uucode.x.types.GraphemeBreakNoControl = .other,

    /// Emoji VS compatibility
    emoji_vs_text: bool = false,
    emoji_vs_emoji: bool = false,

    // Needed for lut.Generator
    pub fn eql(a: Properties, b: Properties) bool {
        return a.width == b.width and
            a.grapheme_break == b.grapheme_break and
            a.emoji_vs_text == b.emoji_vs_text and
            a.emoji_vs_emoji == b.emoji_vs_emoji;
    }

    // Needed for lut.Generator
    pub fn format(
        self: Properties,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            \\.{{
            \\    .width= {},
            \\    .grapheme_break= .{s},
            \\    .emoji_vs_text= {},
            \\    .emoji_vs_emoji= {},
            \\}}
        , .{
            self.width,
            @tagName(self.grapheme_break),
            self.emoji_vs_text,
            self.emoji_vs_emoji,
        });
    }
};
