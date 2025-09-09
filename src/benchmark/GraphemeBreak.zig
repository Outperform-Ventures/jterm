//! This benchmark tests the throughput of grapheme break calculation.
//! This is a common operation in terminal character printing for terminals
//! that support grapheme clustering.
const GraphemeBreak = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const uucode = @import("uucode");
const UTF8Decoder = @import("../terminal/UTF8Decoder.zig");
const unicode = @import("../unicode/main.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

opts: Options,

/// The file, opened in the setup function.
data_f: ?std.fs.File = null,

pub const Options = struct {
    /// The type of codepoint width calculation to use.
    mode: Mode = .noop,

    /// The data to read as a filepath. If this is "-" then
    /// we will read stdin. If this is unset, then we will
    /// do nothing (benchmark is a noop). It'd be more unixy to
    /// use stdin by default but I find that a hanging CLI command
    /// with no interaction is a bit annoying.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// The baseline mode copies the data from the fd into a buffer. This
    /// is used to show the minimal overhead of reading the fd into memory
    /// and establishes a baseline for the other modes.
    noop,

    /// Ghostty's table-based approach.
    table,

    /// uucode implementation
    uucode,
};

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*GraphemeBreak {
    const ptr = try alloc.create(GraphemeBreak);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *GraphemeBreak, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn benchmark(self: *GraphemeBreak) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .table => stepTable,
            .uucode => stepUucode,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *GraphemeBreak = @ptrCast(@alignCast(ptr));

    // Open our data file to prepare for reading. We can do more
    // validation here eventually.
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *GraphemeBreak = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *GraphemeBreak = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());
    var d: UTF8Decoder = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            _ = d.next(c);
        }
    }
}

fn stepTable(ptr: *anyopaque) Benchmark.Error!void {
    const self: *GraphemeBreak = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());
    var d: UTF8Decoder = .{};
    var state: unicode.GraphemeBreakState = .{};
    var cp1: u21 = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp2| {
                std.mem.doNotOptimizeAway(unicode.graphemeBreak(cp1, @intCast(cp2), &state));
                cp1 = cp2;
            }
        }
    }
}

const GraphemeBoundaryClass = uucode.TypeOfX(.grapheme_boundary_class);

const BreakState = enum(u3) {
    default,
    regional_indicator,
    extended_pictographic,
};

fn computeGraphemeBoundaryClass(
    gb1: GraphemeBoundaryClass,
    gb2: GraphemeBoundaryClass,
    state: *BreakState,
) bool {
    // Set state back to default when `gb1` or `gb2` is not expected in sequence.
    switch (state.*) {
        .regional_indicator => {
            if (gb1 != .regional_indicator or gb2 != .regional_indicator) {
                state.* = .default;
            }
        },
        .extended_pictographic => {
            switch (gb1) {
                .extend,
                .zwj,
                .extended_pictographic,
                => {},

                else => state.* = .default,
            }

            switch (gb2) {
                .extend,
                .zwj,
                .extended_pictographic,
                => {},

                else => state.* = .default,
            }
        },
        .default => {},
    }

    // GB6: L x (L | V | LV | VT)
    if (gb1 == .L) {
        if (gb2 == .L or
            gb2 == .V or
            gb2 == .LV or
            gb2 == .LVT) return false;
    }

    // GB7: (LV | V) x (V | T)
    if (gb1 == .LV or gb1 == .V) {
        if (gb2 == .V or gb2 == .T) return false;
    }

    // GB8: (LVT | T) x T
    if (gb1 == .LVT or gb1 == .T) {
        if (gb2 == .T) return false;
    }

    // Handle GB9 (Extend | ZWJ) later, since it can also match the start of
    // GB9c (Indic) and GB11 (Emoji ZWJ)

    // GB9a: SpacingMark
    if (gb2 == .spacing_mark) return false;

    // GB9b: Prepend
    if (gb1 == .prepend) return false;

    // GB11: Emoji ZWJ sequence
    if (gb1 == .extended_pictographic) {
        // start of sequence:

        // In normal operation, we'll be in this state, but
        // precomputeGraphemeBreak iterates all states.
        // std.debug.assert(state.* == .default);

        if (gb2 == .extend or gb2 == .zwj) {
            state.* = .extended_pictographic;
            return false;
        }
        // else, not an Emoji ZWJ sequence
    } else if (state.* == .extended_pictographic) {
        // continue or end sequence:

        if (gb1 == .extend and (gb2 == .extend or gb2 == .zwj)) {
            // continue extend* ZWJ sequence
            return false;
        } else if (gb1 == .zwj and gb2 == .extended_pictographic) {
            // ZWJ -> end of sequence
            state.* = .default;
            return false;
        } else {
            // Not a valid Emoji ZWJ sequence
            state.* = .default;
        }
    }

    // GB12 and GB13: Regional Indicator
    if (gb1 == .regional_indicator and gb2 == .regional_indicator) {
        if (state.* == .default) {
            state.* = .regional_indicator;
            return false;
        } else {
            state.* = .default;
            return true;
        }
    }

    // GB9: x (Extend | ZWJ)
    if (gb2 == .extend or gb2 == .zwj) return false;

    // GB999: Otherwise, break everywhere
    return true;
}

pub fn isBreak(
    cp1: u21,
    cp2: u21,
    state: *BreakState,
) bool {
    const table = comptime uucode.grapheme.precomputeGraphemeBreak(
        GraphemeBoundaryClass,
        BreakState,
        computeGraphemeBoundaryClass,
    );
    const gb1 = uucode.getX(.grapheme_boundary_class, cp1);
    const gb2 = uucode.getX(.grapheme_boundary_class, cp2);
    const result = table.get(gb1, gb2, state.*);
    state.* = result.state;
    return result.result;
}

fn stepUucode(ptr: *anyopaque) Benchmark.Error!void {
    const self: *GraphemeBreak = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());
    var d: UTF8Decoder = .{};
    var state: BreakState = .default;
    var cp1: u21 = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp2| {
                std.mem.doNotOptimizeAway(isBreak(cp1, @intCast(cp2), &state));
                cp1 = cp2;
            }
        }
    }
}

test GraphemeBreak {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *GraphemeBreak = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
