const std = @import("std");
const Allocator = std.mem.Allocator;
const DynamicColor = @import("../color.zig").Dynamic;
const SpecialColor = @import("../color.zig").Special;
const RGB = @import("../color.zig").RGB;

pub const ParseError = Allocator.Error || error{
    MissingOperation,
};

/// The possible operations we support for colors.
pub const Operation = enum {
    osc_110,
    osc_111,
    osc_112,
    osc_113,
    osc_114,
    osc_115,
    osc_116,
    osc_117,
    osc_118,
    osc_119,
};

/// Parse any color operation string. This should NOT include the operation
/// itself, but only the body of the operation. e.g. for "4;a;b;c" the body
/// should be "a;b;c" and the operation should be set accordingly.
///
/// Color parsing is fairly complicated so we pull this out to a specialized
/// function rather than go through our OSC parsing state machine. This is
/// much slower and requires more memory (since we need to buffer the full
/// request) but grants us an easier to understand and testable implementation.
///
/// If color changing ends up being a bottleneck we can optimize this later.
pub fn parse(
    alloc: Allocator,
    op: Operation,
    buf: []const u8,
) ParseError!List {
    var it = std.mem.tokenizeScalar(u8, buf, ';');
    return switch (op) {
        .osc_110 => try parseResetDynamicColor(alloc, .foreground, &it),
        .osc_111 => try parseResetDynamicColor(alloc, .background, &it),
        .osc_112 => try parseResetDynamicColor(alloc, .cursor, &it),
        .osc_113 => try parseResetDynamicColor(alloc, .pointer_foreground, &it),
        .osc_114 => try parseResetDynamicColor(alloc, .pointer_background, &it),
        .osc_115 => try parseResetDynamicColor(alloc, .tektronix_foreground, &it),
        .osc_116 => try parseResetDynamicColor(alloc, .tektronix_background, &it),
        .osc_117 => try parseResetDynamicColor(alloc, .highlight_background, &it),
        .osc_118 => try parseResetDynamicColor(alloc, .tektronix_cursor, &it),
        .osc_119 => try parseResetDynamicColor(alloc, .highlight_foreground, &it),
    };
}

fn parseResetDynamicColor(
    alloc: Allocator,
    color: DynamicColor,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    var result: List = .{};
    if (it.next() != null) return result;
    const req = try result.addOne(alloc);
    req.* = .{ .reset = .{ .dynamic = color } };
    return result;
}

/// A segmented list is used to avoid copying when many operations
/// are given in a single OSC. In most cases, OSC 4/104/etc. send
/// very few so the prealloc is optimized for that.
///
/// The exact prealloc value is chosen arbitrarily assuming most
/// color ops have very few. If we can get empirical data on more
/// typical values we can switch to that.
pub const List = std.SegmentedList(
    Request,
    2,
);

/// A single operation related to the terminal color palette.
pub const Request = union(enum) {
    set: ColoredTarget,
    query: Target,
    reset: Target,
    reset_palette,

    pub const Target = union(enum) {
        palette: u8,
        special: SpecialColor,
        dynamic: DynamicColor,
    };

    pub const ColoredTarget = struct {
        target: Target,
        color: RGB,
    };
};

// OSC 110-119: Reset Dynamic Colors
test "reset dynamic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    inline for (@typeInfo(DynamicColor).@"enum".fields) |field| {
        const color = @field(DynamicColor, field.name);
        const op = @field(Operation, std.fmt.comptimePrint(
            "osc_1{d}",
            .{field.value},
        ));

        // Example script:
        // printf '\e]110\e\\'
        {
            var list = try parse(alloc, op, "");
            errdefer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .reset = .{ .dynamic = color } },
                list.at(0).*,
            );
        }

        // xterm allows a trailing semicolon. script to verify:
        //
        // printf '\e]110;\e\\'
        {
            var list = try parse(alloc, op, ";");
            errdefer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .reset = .{ .dynamic = color } },
                list.at(0).*,
            );
        }

        // xterm does NOT allow any whitespace
        //
        // printf '\e]110 \e\\'
        {
            var list = try parse(alloc, op, " ");
            errdefer list.deinit(alloc);
            try testing.expectEqual(0, list.count());
        }
    }
}
