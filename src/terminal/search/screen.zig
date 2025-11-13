const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("../Screen.zig");
const Active = @import("active.zig").ActiveSearch;

pub const ScreenSearch = struct {
    /// The active area search state
    active: Active,

    /// Search state machine
    const State = enum {
        /// Currently searching the active area
        active,
    };

    pub fn init(
        alloc: Allocator,
        screen: *const Screen,
        needle: []const u8,
    ) Allocator.Error!ScreenSearch {
        _ = screen;

        // Setup our active area search
        var active: Active = try .init(alloc, needle);
        errdefer active.deinit();

        // Store our screen

        return .{
            .active = active,
        };
    }
};
