const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");

/// GTK Settings keys with well-defined types.
pub const Key = enum {
    @"gtk-enable-primary-paste",
    @"gtk-xft-dpi",
    @"gtk-font-name",

    fn Type(comptime self: Key) type {
        return switch (self) {
            .@"gtk-enable-primary-paste" => bool,
            .@"gtk-xft-dpi" => c_int,
            .@"gtk-font-name" => []const u8,
        };
    }

    fn GValueType(comptime self: Key) type {
        return switch (self.Type()) {
            bool => c_int, // Booleans are stored as integers in GTK's internal representation
            c_int => c_int,
            []const u8 => ?[*:0]const u8, // Strings (returned as null-terminated C strings from GTK)
            else => @compileError("Unsupported type for GTK settings"),
        };
    }

    /// Returns true if this setting type requires memory allocation.
    /// this is defensive: types that do not need allocation need to be
    /// explicitly marked here
    fn requiresAllocation(comptime self: Key) bool {
        const T = self.Type();
        return switch (T) {
            bool, c_int => false,
            else => true,
        };
    }
};

/// Reads a GTK setting using the GTK Settings API for non-allocating types.
/// This automatically uses XDG Desktop Portal in Flatpak environments.
///
/// No allocator is required or used. Returns null if the setting is not available or cannot be read.
///
/// Example usage:
///   const enabled = get(.@"gtk-enable-primary-paste");
///   const dpi = get(.@"gtk-xft-dpi");
pub fn get(comptime key: Key) ?key.Type() {
    if (comptime key.requiresAllocation()) {
        @compileError("Allocating types require an allocator; use getAlloc() instead");
    }
    const settings = gtk.Settings.getDefault() orelse return null;
    return getImpl(settings, null, key) catch unreachable;
}

/// Reads a GTK setting using the GTK Settings API, allocating if necessary.
/// This automatically uses XDG Desktop Portal in Flatpak environments.
///
/// The caller must free any returned allocated memory with the provided allocator.
/// Returns null if the setting is not available or cannot be read.
/// May return an allocation error if memory allocation fails.
///
/// Example usage:
///   const theme = try getAlloc(allocator, .gtk_theme_name);
///   defer if (theme) |t| allocator.free(t);
pub fn getAlloc(allocator: std.mem.Allocator, comptime key: Key) !?key.Type() {
    const settings = gtk.Settings.getDefault() orelse return null;
    return getImpl(settings, allocator, key);
}

/// Shared implementation for reading GTK settings.
/// If allocator is null, only non-allocating types can be used.
/// Note: When adding a new type, research if it requires allocation (strings and boxed types do)
/// if allocation is NOT needed, list it inside the switch statement in the function requiresAllocation()
fn getImpl(settings: *gtk.Settings, allocator: ?std.mem.Allocator, comptime key: Key) !?key.Type() {
    const GValType = key.GValueType();
    var value = gobject.ext.Value.new(GValType);
    defer value.unset();

    settings.as(gobject.Object).getProperty(@tagName(key).ptr, &value);

    return switch (key.Type()) {
        bool => value.getInt() != 0, // Booleans are stored as integers in GTK, convert to bool
        c_int => value.getInt(), // Integer types are returned directly
        []const u8 => blk: {
            // Strings: GTK owns the GValue's pointer, so we must duplicate it
            // before the GValue is destroyed by defer value.unset()
            // This is defensive: we have already checked at compile-time that
            // an allocator is provided for allocating types
            const alloc = allocator.?;
            const ptr = value.getString() orelse break :blk null;
            const str = std.mem.span(ptr);
            break :blk try alloc.dupe(u8, str);
        },
        else => @compileError("Unsupported type for GTK settings"),
    };
}

test "Key.Type returns correct types" {
    try std.testing.expectEqual(bool, Key.@"gtk-enable-primary-paste".Type());
    try std.testing.expectEqual(c_int, Key.@"gtk-xft-dpi".Type());
    try std.testing.expectEqual([]const u8, Key.@"gtk-font-name".Type());
}

test "Key.requiresAllocation identifies allocating types" {
    try std.testing.expectEqual(false, Key.@"gtk-enable-primary-paste".requiresAllocation());
    try std.testing.expectEqual(false, Key.@"gtk-xft-dpi".requiresAllocation());
    try std.testing.expectEqual(true, Key.@"gtk-font-name".requiresAllocation());
}

test "Key.GValueType returns correct GObject types" {
    try std.testing.expectEqual(c_int, Key.@"gtk-enable-primary-paste".GValueType());
    try std.testing.expectEqual(c_int, Key.@"gtk-xft-dpi".GValueType());
    try std.testing.expectEqual(?[*:0]const u8, Key.@"gtk-font-name".GValueType());
}

test "@tagName returns correct GTK property names" {
    try std.testing.expectEqualStrings("gtk-enable-primary-paste", @tagName(Key.@"gtk-enable-primary-paste"));
    try std.testing.expectEqualStrings("gtk-xft-dpi", @tagName(Key.@"gtk-xft-dpi"));
    try std.testing.expectEqualStrings("gtk-font-name", @tagName(Key.@"gtk-font-name"));
}
