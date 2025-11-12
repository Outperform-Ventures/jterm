//! Search functionality for the terminal.

pub const PageList = @import("search/pagelist.zig").PageListSearch;

test {
    @import("std").testing.refAllDecls(@This());
}
