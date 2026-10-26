const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.config);

/// Copy a legacy jTerm config out of Ghostty-owned directories if the new
/// jTerm-owned path doesn't exist yet. This is a one-time migration helper and
/// should be a no-op once the new file is present.
pub fn ensureLegacyConfigMigrated(alloc: Allocator) !void {
    const target_path = try preferredTargetPath(alloc);
    defer alloc.free(target_path);

    if (open(target_path)) |f| {
        f.close();
        return;
    } else |_| {}

    const source_candidates = try legacyGhosttySourceCandidates(alloc);
    defer {
        for (source_candidates) |path| alloc.free(path);
        alloc.free(source_candidates);
    }

    for (source_candidates) |source_path| {
        const source = open(source_path) catch continue;
        defer source.close();

        const bytes = try source.readToEndAlloc(alloc, 1024 * 1024);
        defer alloc.free(bytes);
        if (bytes.len == 0) continue;

        if (std.fs.path.dirname(target_path)) |target_dir| {
            try std.fs.cwd().makePath(target_dir);
        }

        var target = try std.fs.createFileAbsolute(target_path, .{ .truncate = true });
        defer target.close();
        try target.writeAll(bytes);
        log.info("migrated legacy config from `{s}` to `{s}`", .{ source_path, target_path });
        return;
    }
}

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "jterm/config" },
    );
}

/// Legacy jTerm XDG home configuration filename.
/// Returned value must be freed by the caller.
pub fn legacyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "jterm/config.ghostty" },
    );
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    // If the XDG path exists, use that.
    const xdg_path = try defaultXdgPath(alloc);
    if (open(xdg_path)) |f| {
        f.close();
        return xdg_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(xdg_path);
    const legacy_xdg_path = try legacyDefaultXdgPath(alloc);
    if (open(legacy_xdg_path)) |f| {
        f.close();
        alloc.free(xdg_path);
        return legacy_xdg_path;
    } else |_| {}

    // Legacy path and XDG path both don't exist. Return the
    // new one.
    alloc.free(legacy_xdg_path);
    return xdg_path;
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}

/// Legacy jTerm macOS Application Support configuration filename.
/// Returned value must be freed by the caller.
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config.ghostty");
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    // If the app support path exists, use that.
    const app_support_path = try defaultAppSupportPath(alloc);
    if (open(app_support_path)) |f| {
        f.close();
        return app_support_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(app_support_path);
    const legacy_app_support_path = try legacyDefaultAppSupportPath(alloc);
    if (open(legacy_app_support_path)) |f| {
        f.close();
        alloc.free(app_support_path);
        return legacy_app_support_path;
    } else |_| {}

    // Legacy path and app support path both don't exist. Return the
    // new one.
    alloc.free(legacy_app_support_path);
    return app_support_path;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    try ensureLegacyConfigMigrated(alloc);
    switch (builtin.os.tag) {
        .macos => {
            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try preferredAppSupportPath(alloc);
            const app_support_file = open(app_support_path) catch {
                // Try the XDG path if it exists
                const xdg_path = try preferredXdgPath(alloc);
                const xdg_file = open(xdg_path) catch {
                    // If neither file exists, use app support
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close();
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close();
            return app_support_path;
        },

        // All other platforms use XDG only
        else => return try preferredXdgPath(alloc),
    }
}

fn preferredTargetPath(alloc: Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => defaultAppSupportPath(alloc),
        else => defaultXdgPath(alloc),
    };
}

fn legacyGhosttySourceCandidates(alloc: Allocator) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| alloc.free(path);
        paths.deinit(alloc);
    }

    if (comptime builtin.os.tag == .macos) {
        try paths.append(alloc, try legacyGhosttyAppSupportPath(alloc, "config"));
        try paths.append(alloc, try legacyGhosttyAppSupportPath(alloc, "config.ghostty"));
    }

    try paths.append(alloc, try internal_os.xdg.config(alloc, .{ .subdir = "ghostty/config" }));
    try paths.append(alloc, try internal_os.xdg.config(alloc, .{ .subdir = "ghostty/config.ghostty" }));

    return try paths.toOwnedSlice(alloc);
}

fn legacyGhosttyAppSupportPath(alloc: Allocator, file_name: []const u8) ![]const u8 {
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{
        home,
        "Library",
        "Application Support",
        "com.mitchellh.ghostty",
        file_name,
    });
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(path: []const u8) OpenFileError!std.fs.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}
