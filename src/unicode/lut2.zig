const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// This whole file is based on the algorithm described here:
// https://here-be-braces.com/fast-lookup-of-unicode-properties/

const set_size = @typeInfo(usize).int.bits;
// const Set = std.bit_set.ArrayBitSet(usize, set_size);
const Set = std.bit_set.IntegerBitSet(set_size);
const cp_shift = std.math.log2_int(u21, set_size);
const cp_mask = set_size - 1;

/// Creates a type that is able to generate a 2-level lookup table
/// from a Unicode codepoint to a mapping of type bool. The lookup table
/// generally is expected to be codegen'd and then reloaded, although it
/// can in theory be generated at runtime.
///
/// Context must have one function:
///   - `get(Context, u21) bool`: returns the mapping for a given codepoint
///
pub fn Generator(
    comptime Context: type,
) type {
    return struct {
        const Self = @This();

        /// Mapping of a block to its index in the stage2 array.
        const SetMap = std.HashMap(
            Set,
            u16,
            struct {
                pub fn hash(ctx: @This(), k: Set) u64 {
                    _ = ctx;
                    var hasher = std.hash.Wyhash.init(0);
                    std.hash.autoHashStrat(&hasher, k, .DeepRecursive);
                    return hasher.final();
                }

                pub fn eql(ctx: @This(), a: Set, b: Set) bool {
                    _ = ctx;
                    return a.eql(b);
                }
            },
            std.hash_map.default_max_load_percentage,
        );

        ctx: Context = undefined,

        /// Generate the lookup tables. The arrays in the return value
        /// are owned by the caller and must be freed.
        pub fn generate(self: *const Self, alloc: Allocator) !Tables {
            var min: u21 = std.math.maxInt(u21);
            var max: u21 = std.math.minInt(u21);

            // Maps block => stage2 index
            var set_map = SetMap.init(alloc);
            defer set_map.deinit();

            // Our stages
            var stage1 = std.ArrayList(u16).init(alloc);
            defer stage1.deinit();
            var stage2 = std.ArrayList(Set).init(alloc);
            defer stage2.deinit();

            var set: Set = .initEmpty();

            // ensure that the 1st entry is always all false
            try stage2.append(set);
            try set_map.putNoClobber(set, 0);

            for (0..std.math.maxInt(u21) + 1) |cp_| {
                const cp: u21 = @intCast(cp_);
                const high = cp >> cp_shift;
                const low = cp & cp_mask;

                if (self.ctx.get(cp)) {
                    if (cp < min) min = cp;
                    if (cp > max) max = cp;
                    set.set(low);
                }

                // If we still have space and we're not done with codepoints,
                // we keep building up the block. Conversely: we finalize this
                // block if we've filled it or are out of codepoints.
                if (low + 1 < set_size and cp != std.math.maxInt(u21)) continue;

                // Look for the stage2 index for this block. If it doesn't exist
                // we add it to stage2 and update the mapping.
                const gop = try set_map.getOrPut(set);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.math.cast(
                        u16,
                        stage2.items.len,
                    ) orelse return error.Stage2TooLarge;
                    try stage2.append(set);
                }

                // Map stage1 => stage2 and reset our block
                try stage1.append(gop.value_ptr.*);
                set = .initEmpty();
                assert(stage1.items.len - 1 == high);
            }

            // All of our lengths must fit in a u16 for this to work
            assert(stage1.items.len <= std.math.maxInt(u16));
            assert(stage2.items.len <= std.math.maxInt(u16));

            const stage1_owned = try stage1.toOwnedSlice();
            errdefer alloc.free(stage1_owned);
            const stage2_owned = try stage2.toOwnedSlice();
            errdefer alloc.free(stage2_owned);

            return .{
                .min = min,
                .max = max,
                .stage1 = stage1_owned,
                .stage2 = stage2_owned,
            };
        }
    };
}

/// Creates a type that given a 3-level lookup table, can be used to
/// look up a mapping for a given codepoint, encode it out to Zig, etc.
pub const Tables = struct {
    const Self = @This();

    min: u21,
    max: u21,
    stage1: []const u16,
    stage2: []const Set,

    /// Given a codepoint, returns the mapping for that codepoint.
    pub fn get(self: *const Self, cp: u21) bool {
        if (cp < self.min) return false;
        if (cp > self.max) return false;
        const high = cp >> cp_shift;
        const stage2 = self.stage1[high];
        // take advantage of the fact that the first entry is always all false
        if (stage2 == 0) return false;
        const low = cp & cp_mask;
        return self.stage2[stage2].isSet(low);
    }

    /// Writes the lookup table as Zig to the given writer. The
    /// written file exports three constants: stage1, stage2, and
    /// stage3. These can be used to rebuild the lookup table in Zig.
    pub fn writeZig(self: *const Self, writer: anytype) !void {
        try writer.print(
            \\//! This file is auto-generated. Do not edit.
            \\const std = @import("std");
            \\
            \\pub const min: u21 = {};
            \\pub const max: u21 = {};
            \\
            \\pub const stage1: [{}]u16 = .{{
        , .{ self.min, self.max, self.stage1.len });
        for (self.stage1) |entry| try writer.print("{},", .{entry});

        try writer.print(
            \\
            \\}};
            \\
            \\pub const Set = std.bit_set.IntegerBitSet({d});
            \\pub const stage2: [{d}]Set = .{{
            \\
        , .{ set_size, self.stage2.len });
        // for (self.stage2) |entry| {
        //     try writer.print("    .{{\n", .{});
        //     try writer.print("        .masks = [{d}]{s}{{\n", .{ entry.masks.len, @typeName(Set.MaskInt) });
        //     for (entry.masks) |mask| {
        //         try writer.print("            {d},\n", .{mask});
        //     }
        //     try writer.print("        }},\n", .{});
        //     try writer.print("    }},\n", .{});
        // }
        for (self.stage2) |entry| {
            try writer.print("    .{{ .mask = {d} }},\n", .{entry.mask});
        }
        try writer.writeAll("};\n");
    }
};
