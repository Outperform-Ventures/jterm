const std = @import("std");
const builtin = @import("builtin");
const OptionAsAlt = @import("config.zig").OptionAsAlt;

/// Aliases for modifier names.
pub const alias: []const struct { []const u8, Mod } = &.{
    .{ "cmd", .super },
    .{ "command", .super },
    .{ "opt", .alt },
    .{ "option", .alt },
    .{ "control", .ctrl },
};

/// Single modifier
pub const Mod = enum {
    shift,
    ctrl,
    alt,
    super,

    pub const Side = enum(u1) { left, right };
};

/// A bitmask for all key modifiers.
///
/// IMPORTANT: Any changes here update include/ghostty.h
pub const Mods = packed struct(Mods.Backing) {
    pub const Backing = u16;

    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    sides: side = .{},
    _padding: u6 = 0,

    /// Tracks the side that is active for any given modifier. Note
    /// that this doesn't confirm a modifier is pressed; you must check
    /// the bool for that in addition to this.
    ///
    /// Not all platforms support this, check apprt for more info.
    pub const side = packed struct(u4) {
        shift: Mod.Side = .left,
        ctrl: Mod.Side = .left,
        alt: Mod.Side = .left,
        super: Mod.Side = .left,
    };

    /// Integer value of this struct.
    pub fn int(self: Mods) Backing {
        return @bitCast(self);
    }

    /// Returns true if no modifiers are set.
    pub fn empty(self: Mods) bool {
        return self.int() == 0;
    }

    /// Returns true if two mods are equal.
    pub fn equal(self: Mods, other: Mods) bool {
        return self.int() == other.int();
    }

    /// Return mods that are only relevant for bindings.
    pub fn binding(self: Mods) Mods {
        return .{
            .shift = self.shift,
            .ctrl = self.ctrl,
            .alt = self.alt,
            .super = self.super,
        };
    }

    /// Perform `self &~ other` to remove the other mods from self.
    pub fn unset(self: Mods, other: Mods) Mods {
        return @bitCast(self.int() & ~other.int());
    }

    /// Returns the mods without locks set.
    pub fn withoutLocks(self: Mods) Mods {
        var copy = self;
        copy.caps_lock = false;
        copy.num_lock = false;
        return copy;
    }

    /// Return the mods to use for key translation. This handles settings
    /// like macos-option-as-alt. The translation mods should be used for
    /// translation but never sent back in for the key callback.
    pub fn translation(self: Mods, option_as_alt: OptionAsAlt) Mods {
        var result = self;

        // macos-option-as-alt for darwin
        if (comptime builtin.target.os.tag.isDarwin()) alt: {
            // Alt has to be set only on the correct side
            switch (option_as_alt) {
                .false => break :alt,
                .true => {},
                .left => if (self.sides.alt == .right) break :alt,
                .right => if (self.sides.alt == .left) break :alt,
            }

            // Unset alt
            result.alt = false;
        }

        return result;
    }

    /// Checks to see if super is on (MacOS) or ctrl.
    pub fn ctrlOrSuper(self: Mods) bool {
        if (comptime builtin.target.os.tag.isDarwin()) {
            return self.super;
        }
        return self.ctrl;
    }

    // For our own understanding
    test {
        const testing = std.testing;
        try testing.expectEqual(@as(Backing, @bitCast(Mods{})), @as(Backing, 0b0));
        try testing.expectEqual(
            @as(Backing, @bitCast(Mods{ .shift = true })),
            @as(Backing, 0b0000_0001),
        );
    }

    test "translation macos-option-as-alt" {
        if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

        const testing = std.testing;

        // Unset
        {
            const mods: Mods = .{};
            const result = mods.translation(.true);
            try testing.expectEqual(result, mods);
        }

        // Set
        {
            const mods: Mods = .{ .alt = true };
            const result = mods.translation(.true);
            try testing.expectEqual(Mods{}, result);
        }

        // Set but disabled
        {
            const mods: Mods = .{ .alt = true };
            const result = mods.translation(.false);
            try testing.expectEqual(result, mods);
        }

        // Set wrong side
        {
            const mods: Mods = .{ .alt = true, .sides = .{ .alt = .right } };
            const result = mods.translation(.left);
            try testing.expectEqual(result, mods);
        }
        {
            const mods: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
            const result = mods.translation(.right);
            try testing.expectEqual(result, mods);
        }

        // Set with other mods
        {
            const mods: Mods = .{ .alt = true, .shift = true };
            const result = mods.translation(.true);
            try testing.expectEqual(Mods{ .shift = true }, result);
        }
    }
};

/// Modifier remapping. See `key-remap` in Config.zig for detailed docs.
pub const RemapSet = struct {
    /// Available mappings.
    map: std.ArrayHashMapUnmanaged(Mods, Mods),

    /// The mask of remapped modifiers that can be used to quickly
    /// check if some input mods need remapping.
    mask: Mods.Backing,
};
