//! GhosttyZig generates the Zig modules that Ghostty exports
//! for downstream usage.
const GhosttyZig = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

const vt_options = @import("../terminal/build_options.zig");

vt: *std.Build.Module,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !GhosttyZig {
    const vt = b.addModule("ghostty-vt", .{
        .root_source_file = b.path("src/lib_vt.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,

        // SIMD require libc/libcpp (both) but otherwise we don't care.
        .link_libc = if (cfg.simd) true else null,
        .link_libcpp = if (cfg.simd) true else null,
    });
    vt_options.addOptions(b, vt, .{
        .artifact = .lib,
        .simd = cfg.simd,

        // We presently don't allow Oniguruma in our Zig module at all.
        // We should expose this as a build option in the future so we can
        // conditionally do this.
        .oniguruma = false,

        .slow_runtime_safety = switch (cfg.optimize) {
            .Debug => true,
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => false,
        },
    });

    // We always need unicode tables
    deps.unicode_tables.addModuleImport(vt);

    // If SIMD is enabled, add all our SIMD dependencies.
    if (cfg.simd) {
        try SharedDeps.addSimd(b, vt, null);
    }

    return .{ .vt = vt };
}
