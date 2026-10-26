const std = @import("std");
const schema = @import("remote_control_schema.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    _ = args.next();
    const mode = args.next() orelse return usage();

    const stdout = std.fs.File.stdout();

    if (std.mem.eql(u8, mode, "global-help")) {
        const text = try schema.renderGlobalHelp(gpa);
        defer gpa.free(text);
        try stdout.writeAll(text);
        return;
    }

    if (std.mem.eql(u8, mode, "reference")) {
        const text = try schema.renderReferenceDoc(gpa);
        defer gpa.free(text);
        try stdout.writeAll(text);
        return;
    }

    if (std.mem.eql(u8, mode, "manpage")) {
        const text = try schema.renderManpageDoc(gpa);
        defer gpa.free(text);
        try stdout.writeAll(text);
        return;
    }

    if (std.mem.eql(u8, mode, "command-help")) {
        const command_name = args.next() orelse return usage();
        const text = (try schema.renderCommandHelp(gpa, command_name)) orelse return usage();
        defer gpa.free(text);
        try stdout.writeAll(text);
        return;
    }

    return usage();
}

fn usage() !void {
    try std.fs.File.stderr().writeAll(
        \\Usage:
        \\  zig run src/cli/remote_control_docgen.zig -- global-help
        \\  zig run src/cli/remote_control_docgen.zig -- reference
        \\  zig run src/cli/remote_control_docgen.zig -- manpage
        \\  zig run src/cli/remote_control_docgen.zig -- command-help <command>
        \\
    );
    return error.InvalidArguments;
}
