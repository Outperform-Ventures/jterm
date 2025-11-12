//! Search functionality for the terminal.

pub const PageList = @import("search/pagelist.zig").PageListSearch;
pub const Thread = @import("search/Thread.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
