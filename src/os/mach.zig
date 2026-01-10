const std = @import("std");

/// macOS virtual memory tags for use with mach_vm_map/mach_vm_allocate.
/// These identify memory regions in tools like vmmap and Instruments.
pub const VMTag = enum(u8) {
    application_specific_1 = 240,
    application_specific_2 = 241,
    application_specific_3 = 242,
    application_specific_4 = 243,
    application_specific_5 = 244,
    application_specific_6 = 245,
    application_specific_7 = 246,
    application_specific_8 = 247,
    application_specific_9 = 248,
    application_specific_10 = 249,
    application_specific_11 = 250,
    application_specific_12 = 251,
    application_specific_13 = 252,
    application_specific_14 = 253,
    application_specific_15 = 254,
    application_specific_16 = 255,

    // We ignore the rest because we never realistic set them.
    _,

    /// Converts the tag to the format expected by mach_vm_map/mach_vm_allocate.
    /// Equivalent to C macro: VM_MAKE_TAG(tag)
    pub fn make(self: VMTag) i32 {
        return @bitCast(@as(u32, @intFromEnum(self)) << 24);
    }
};

test "VMTag.make" {
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 240) << 24)), VMTag.application_specific_1.make());
}
