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
    osc_4,
    osc_5,
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
        .osc_4 => try parseGetSetAnsiColor(alloc, .osc_4, &it),
        .osc_5 => try parseGetSetAnsiColor(alloc, .osc_5, &it),
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

/// OSC 4/5
fn parseGetSetAnsiColor(
    alloc: Allocator,
    comptime op: Operation,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    // Note: in ANY error scenario below we return the accumulated results.
    // This matches the xterm behavior (see misc.c ChangeAnsiColorRequest)

    var result: List = .{};
    errdefer result.deinit(alloc);
    while (true) {
        // We expect a `c; spec` pair. If either doesn't exist then
        // we return the results up to this point.
        const color_str = it.next() orelse return result;
        const spec_str = it.next() orelse return result;

        // Color must be numeric. u9 because that'll fit our palette + special
        const color: u9 = std.fmt.parseInt(
            u9,
            color_str,
            10,
        ) catch return result;

        // Parse the color.
        const target: Request.Target = switch (op) {
            // OSC5 maps directly to the Special enum.
            .osc_5 => .{ .special = std.meta.intToEnum(
                SpecialColor,
                std.math.cast(u3, color) orelse return result,
            ) catch return result },

            // OSC4 maps 0-255 to palette, 256-259 to special offset
            // by the palette count.
            .osc_4 => if (std.math.cast(u8, color)) |idx| .{
                .palette = idx,
            } else .{ .special = std.meta.intToEnum(
                SpecialColor,
                std.math.cast(u3, color - 256) orelse return result,
            ) catch return result },

            else => comptime unreachable,
        };

        // "?" always results in a query.
        if (std.mem.eql(u8, spec_str, "?")) {
            const req = try result.addOne(alloc);
            req.* = .{ .query = target };
            continue;
        }

        const rgb = RGB.parse(spec_str) catch return result;
        const req = try result.addOne(alloc);
        req.* = .{ .set = .{
            .target = target,
            .color = rgb,
        } };
    }
}

/// OSC 110-119: Reset Dynamic Colors
fn parseResetDynamicColor(
    alloc: Allocator,
    color: DynamicColor,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    var result: List = .{};
    errdefer result.deinit(alloc);
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

test "osc4" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Test every palette index
    for (0..std.math.maxInt(u8)) |idx| {
        // Simple color set
        // printf '\e]4;0;red\\'
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red",
                .{idx},
            );
            defer alloc.free(body);

            var list = try parse(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .palette = @intCast(idx) },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }

        // Simple color query
        // printf '\e]4;0;?\\'
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};?",
                .{idx},
            );
            defer alloc.free(body);

            var list = try parse(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .query = .{ .palette = @intCast(idx) } },
                list.at(0).*,
            );
        }

        // Trailing invalid data produces results up to that point
        // printf '\e]4;0;red;\e\\'
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red;",
                .{idx},
            );
            defer alloc.free(body);

            var list = try parse(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .palette = @intCast(idx) },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }

        // Whitespace doesn't produce a working value in xterm but we
        // allow it because Kitty does and it seems harmless.
        //
        // printf '\e]4;0;red \e\\'
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red ",
                .{idx},
            );
            defer alloc.free(body);

            var list = try parse(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .palette = @intCast(idx) },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
    }

    // Test every special color
    for (0..@typeInfo(SpecialColor).@"enum".fields.len) |i| {
        const special = try std.meta.intToEnum(SpecialColor, i);

        // Simple color set
        // printf '\e]4;256;red\\'
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red",
                .{256 + i},
            );
            defer alloc.free(body);

            var list = try parse(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .special = special },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
    }
}

test "osc5" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Test every special color
    for (0..@typeInfo(SpecialColor).@"enum".fields.len) |i| {
        const special = try std.meta.intToEnum(SpecialColor, i);

        // Simple color set
        // printf '\e]4;256;red\\'
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red",
                .{i},
            );
            defer alloc.free(body);

            var list = try parse(alloc, .osc_5, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .special = special },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
    }
}

test "osc4: multiple requests" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // printf '\e]4;0;red;1;blue\e\\'
    {
        var list = try parse(
            alloc,
            .osc_4,
            "0;red;1;blue",
        );
        defer list.deinit(alloc);
        try testing.expectEqual(2, list.count());
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 0 },
                .color = RGB{ .r = 255, .g = 0, .b = 0 },
            } },
            list.at(0).*,
        );
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 1 },
                .color = RGB{ .r = 0, .g = 0, .b = 255 },
            } },
            list.at(1).*,
        );
    }

    // Multiple requests with same index overwrite each other
    // printf '\e]4;0;red;0;blue\e\\'
    {
        var list = try parse(
            alloc,
            .osc_4,
            "0;red;0;blue",
        );
        defer list.deinit(alloc);
        try testing.expectEqual(2, list.count());
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 0 },
                .color = RGB{ .r = 255, .g = 0, .b = 0 },
            } },
            list.at(0).*,
        );
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 0 },
                .color = RGB{ .r = 0, .g = 0, .b = 255 },
            } },
            list.at(1).*,
        );
    }
}

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
            defer list.deinit(alloc);
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
            defer list.deinit(alloc);
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
            defer list.deinit(alloc);
            try testing.expectEqual(0, list.count());
        }
    }
}
