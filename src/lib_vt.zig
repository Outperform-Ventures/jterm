//! This is the public API of the ghostty-vt Zig module.

// The public API below reproduces a lot of terminal/main.zig but
// is separate because (1) we need our root file to be in `src/`
// so we can access other directories and (2) we may want to withhold
// parts of `terminal` that are not ready for public consumption
// or are too Ghostty-internal.
const terminal = @import("terminal/main.zig");
pub const Parser = terminal.Parser;
pub const Terminal = terminal.Terminal;

test {
    _ = terminal;
}
