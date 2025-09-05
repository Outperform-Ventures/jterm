const UnicodeTables = @This();

const std = @import("std");
const Config = @import("Config.zig");

/// The exe.
props_exe: *std.Build.Step.Compile,
symbols1_exe: *std.Build.Step.Compile,
symbols2_exe: *std.Build.Step.Compile,

/// The output path for the unicode tables
props_output: std.Build.LazyPath,
symbols1_output: std.Build.LazyPath,
symbols2_output: std.Build.LazyPath,

pub fn init(b: *std.Build) !UnicodeTables {
    const props_exe = b.addExecutable(.{
        .name = "props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/props.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    const symbols1_exe = b.addExecutable(.{
        .name = "symbols1-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/symbols1.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    const symbols2_exe = b.addExecutable(.{
        .name = "symbols2-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/symbols2.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    if (b.lazyDependency("ziglyph", .{
        .target = b.graph.host,
    })) |ziglyph_dep| {
        inline for (&.{ props_exe, symbols1_exe, symbols2_exe }) |exe| {
            exe.root_module.addImport(
                "ziglyph",
                ziglyph_dep.module("ziglyph"),
            );
        }
    }

    const props_run = b.addRunArtifact(props_exe);
    const symbols1_run = b.addRunArtifact(symbols1_exe);
    const symbols2_run = b.addRunArtifact(symbols2_exe);

    return .{
        .props_exe = props_exe,
        .symbols1_exe = symbols1_exe,
        .symbols2_exe = symbols2_exe,
        .props_output = props_run.captureStdOut(),
        .symbols1_output = symbols1_run.captureStdOut(),
        .symbols2_output = symbols2_run.captureStdOut(),
    };
}

/// Add the "unicode_tables" import.
pub fn addImport(self: *const UnicodeTables, step: *std.Build.Step.Compile) void {
    self.props_output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("unicode_tables", .{
        .root_source_file = self.props_output,
    });
    self.symbols1_output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("symbols1_tables", .{
        .root_source_file = self.symbols1_output,
    });
    self.symbols2_output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("symbols2_tables", .{
        .root_source_file = self.symbols2_output,
    });
}

/// Install the exe
pub fn install(self: *const UnicodeTables, b: *std.Build) void {
    b.installArtifact(self.props_exe);
    b.installArtifact(self.symbols1_exe);
    b.installArtifact(self.symbols2_exe);
}
