const std = @import("std");

pub const Options = struct {
    /// The target artifact to build. This will gate some functionality.
    artifact: Artifact = .ghostty,

    /// True if we should enable the "slow" runtime safety checks. These
    /// are runtime safety checks that are slower than typical and should
    /// generally be disabled in production builds.
    slow_runtime_safety: bool = false,
};

pub const Artifact = enum {
    /// Ghostty application
    ghostty,

    /// libghostty-vt, Zig module
    lib,
};

/// Add the required build options for the terminal module.
pub fn addOptions(
    b: *std.Build,
    m: *std.Build.Module,
    v: Options,
) void {
    const opts = b.addOptions();
    opts.addOption(Artifact, "artifact", v.artifact);
    opts.addOption(bool, "slow_runtime_safety", v.slow_runtime_safety);
    m.addOptions("terminal_options", opts);
}
