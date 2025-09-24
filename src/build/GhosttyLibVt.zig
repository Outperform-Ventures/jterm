const GhosttyLibVt = @This();

const std = @import("std");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const GhosttyZig = @import("GhosttyZig.zig");
const SharedDeps = @import("SharedDeps.zig");
const LibtoolStep = @import("LibtoolStep.zig");
const LipoStep = @import("LipoStep.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The artifact result
artifact: *std.Build.Step.InstallArtifact,

/// The final library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,

pub fn initShared(
    b: *std.Build,
    zig: *const GhosttyZig,
) !GhosttyLibVt {
    const target = zig.vt.resolved_target.?;
    const lib = b.addSharedLibrary(.{
        .name = "ghostty-vt",
        .root_module = zig.vt,
    });
    lib.installHeader(
        b.path("include/ghostty-vt.h"),
        "ghostty-vt.h",
    );

    // Get our debug symbols
    const dsymutil: ?std.Build.LazyPath = dsymutil: {
        if (!target.result.os.tag.isDarwin()) {
            break :dsymutil null;
        }

        const dsymutil = RunStep.create(b, "dsymutil");
        dsymutil.addArgs(&.{"dsymutil"});
        dsymutil.addFileArg(lib.getEmittedBin());
        dsymutil.addArgs(&.{"-o"});
        const output = dsymutil.addOutputFileArg("libghostty-vt.dSYM");
        break :dsymutil output;
    };

    return .{
        .step = &lib.step,
        .artifact = b.addInstallArtifact(lib, .{}),
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
    };
}

pub fn install(
    self: *const GhosttyLibVt,
    step: *std.Build.Step,
) void {
    step.dependOn(&self.artifact.step);
}
