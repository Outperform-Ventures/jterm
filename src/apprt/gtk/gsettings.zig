const std = @import("std");
const builtin = @import("builtin");
const gtk = @import("gtk");
const gobject = @import("gobject");

/// Reads a GTK setting using the GTK Settings API.
/// This automatically uses XDG Desktop Portal in Flatpak environments.
/// Returns null if not on a GTK-supported platform or if the setting cannot be read.
///
/// Supported platforms: Linux, FreeBSD
/// Supported types: bool, c_int
///
/// Example usage:
///   const enabled = readSetting(bool, "gtk-enable-primary-paste");
///   const dpi = readSetting(c_int, "gtk-xft-dpi");
pub fn readSetting(comptime T: type, key: [*:0]const u8) ?T {
    // Only available on systems that use GTK (Linux, FreeBSD)
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .freebsd) return null;

    const settings = gtk.Settings.getDefault() orelse return null;

    // For bool and c_int, we use c_int as the underlying GObject type
    // because GTK boolean properties are stored as integers
    var value = gobject.ext.Value.new(c_int);
    defer value.unset();

    settings.as(gobject.Object).getProperty(key, &value);

    return switch (T) {
        bool => value.getInt() != 0,
        c_int => value.getInt(),
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "' for GTK setting. Supported types: bool, c_int"),
    };
}
