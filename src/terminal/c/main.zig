pub const osc = @import("osc.zig");

// The full C API, unexported.
pub const osc_new = osc.new;
pub const osc_free = osc.free;

test {
    _ = osc;

    // We want to make sure we run the tests for the C allocator interface.
    _ = @import("../../lib/allocator.zig");
}
