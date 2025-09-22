const std = @import("std");

pub const Options = struct {
    /// The target artifact to build. This will gate some functionality.
    artifact: Artifact = .ghostty,

    /// Whether Oniguruma regex support is available. If this isn't
    /// available, some features will be disabled. This may be outdated,
    /// but the specific disabled features are:
    ///
    /// - Kitty graphics protocol
    /// - Tmux control mode
    ///
    oniguruma: bool = true,

    /// Whether to build SIMD-accelerated code paths. This pulls in more
    /// build-time dependencies and adds libc as a runtime dependency,
    /// but results in significant performance improvements.
    simd: bool = true,

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
    opts.addOption(bool, "oniguruma", v.oniguruma);
    opts.addOption(bool, "simd", v.simd);
    opts.addOption(bool, "slow_runtime_safety", v.slow_runtime_safety);

    // These are synthesized based on other options.
    opts.addOption(bool, "kitty_graphics", v.oniguruma);
    opts.addOption(bool, "tmux_control_mode", v.oniguruma);

    m.addOptions("terminal_options", opts);
}
