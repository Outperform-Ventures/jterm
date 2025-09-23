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

/// The final library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,

/// Library extension, e.g. "dylib", "so", "dll"
ext: []const u8,

pub fn initShared(
    b: *std.Build,
    zig: *const GhosttyZig,
) !GhosttyLibVt {
    const target = zig.vt.resolved_target.?;
    const lib = b.addSharedLibrary(.{
        .name = "ghostty-vt",
        .root_module = zig.vt,
    });

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
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
        .ext = Config.sharedLibExt(target),
    };
}

pub fn install(
    self: *const GhosttyLibVt,
    step: *std.Build.Step,
    name: []const u8,
) void {
    const b = self.step.owner;
    const lib_install = b.addInstallLibFile(
        self.output,
        b.fmt("{s}.{s}", .{ name, self.ext }),
    );
    step.dependOn(&lib_install.step);
}

pub fn installHeader(
    self: *const GhosttyLibVt,
    step: *std.Build.Step,
) void {
    const b = self.step.owner;
    const header_install = b.addInstallHeaderFile(
        b.path("include/ghostty-vt.h"),
        "ghostty-vt.h",
    );
    step.dependOn(&header_install.step);
}
