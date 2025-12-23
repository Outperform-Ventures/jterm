const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_key_state_overlay);

/// An overlay that displays the current key table stack and pending key sequence.
/// This helps users understand what key bindings are active and what keys they've
/// pressed in a multi-key sequence.
pub const KeyStateOverlay = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyKeyStateOverlay",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const active = struct {
            pub const name = "active";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("active"),
                },
            );
        };

        pub const tables = struct {
            pub const name = "tables";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getTables,
                            .getter_transfer = .full,
                            .setter = setTables,
                            .setter_transfer = .full,
                        },
                    ),
                },
            );
        };

        pub const @"has-tables" = struct {
            pub const name = "has-tables";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasTables },
                    ),
                },
            );
        };

        pub const sequence = struct {
            pub const name = "sequence";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getSequence,
                            .getter_transfer = .full,
                            .setter = setSequence,
                            .setter_transfer = .full,
                        },
                    ),
                },
            );
        };

        pub const @"has-sequence" = struct {
            pub const name = "has-sequence";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasSequence },
                    ),
                },
            );
        };

        pub const pending = struct {
            pub const name = "pending";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("pending"),
                },
            );
        };

        pub const @"valign-target" = struct {
            pub const name = "valign-target";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .default = .end,
                    .accessor = C.privateShallowFieldAccessor("valign_target"),
                },
            );
        };
    };

    const Private = struct {
        /// Whether the overlay is active/visible.
        active: bool = false,

        /// The key table stack.
        tables: ?*ext.StringList = null,

        /// The key sequence.
        sequence: ?*ext.StringList = null,

        /// Whether we're waiting for more keys in a sequence.
        pending: bool = false,

        /// Target vertical alignment for the overlay.
        valign_target: gtk.Align = .end,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn getTables(self: *Self) ?*ext.StringList {
        const priv = self.private();
        if (priv.tables) |tables| {
            return ext.StringList.create(tables.allocator(), tables.strings) catch null;
        }
        return null;
    }

    fn getSequence(self: *Self) ?*ext.StringList {
        const priv = self.private();
        if (priv.sequence) |sequence| {
            return ext.StringList.create(sequence.allocator(), sequence.strings) catch null;
        }
        return null;
    }

    fn setTables(self: *Self, value: ?*ext.StringList) void {
        const priv = self.private();
        if (priv.tables) |old| {
            old.destroy();
            priv.tables = null;
        }

        priv.tables = value;
        self.as(gobject.Object).notifyByPspec(properties.@"has-tables".impl.param_spec);
    }

    fn setSequence(self: *Self, value: ?*ext.StringList) void {
        const priv = self.private();
        if (priv.sequence) |old| {
            old.destroy();
            priv.sequence = null;
        }

        priv.sequence = value;
        self.as(gobject.Object).notifyByPspec(properties.@"has-sequence".impl.param_spec);
    }

    fn getHasTables(self: *Self) bool {
        return self.private().tables != null;
    }

    fn getHasSequence(self: *Self) bool {
        return self.private().sequence != null;
    }

    fn closureShowChevron(
        _: *Self,
        has_tables: bool,
        has_sequence: bool,
    ) callconv(.c) c_int {
        return if (has_tables and has_sequence) 1 else 0;
    }

    //---------------------------------------------------------------
    // Template callbacks

    fn onDragEnd(
        _: *gtk.GestureDrag,
        _: f64,
        offset_y: f64,
        self: *Self,
    ) callconv(.c) void {
        // Key state overlay only moves between top-center and bottom-center.
        // Horizontal alignment is always center.
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const parent = widget.getParent() orelse return;

        const parent_height: f64 = @floatFromInt(parent.getAllocatedHeight());
        const self_height: f64 = @floatFromInt(widget.getAllocatedHeight());

        const self_y: f64 = if (priv.valign_target == .start) 0 else parent_height - self_height;
        const new_y = self_y + offset_y + (self_height / 2);

        const new_valign: gtk.Align = if (new_y > parent_height / 2) .end else .start;

        if (new_valign != priv.valign_target) {
            priv.valign_target = new_valign;
            self.as(gobject.Object).notifyByPspec(properties.@"valign-target".impl.param_spec);
            self.as(gtk.Widget).queueResize();
        }
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.tables) |v| {
            v.destroy();
        }
        if (priv.sequence) |v| {
            v.destroy();
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "key-state-overlay",
                }),
            );

            // Template Callbacks
            class.bindTemplateCallback("on_drag_end", &onDragEnd);
            class.bindTemplateCallback("show_chevron", &closureShowChevron);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.active.impl,
                properties.tables.impl,
                properties.@"has-tables".impl,
                properties.sequence.impl,
                properties.@"has-sequence".impl,
                properties.pending.impl,
                properties.@"valign-target".impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
