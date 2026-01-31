const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const renderer = @import("../../renderer.zig");

const log = std.log.scoped(.inspector_renderer);

/// Renderer information inspector widget.
pub const Info = struct {
    features: std.AutoArrayHashMapUnmanaged(
        std.meta.Tag(renderer.Overlay.Feature),
        renderer.Overlay.Feature,
    ),

    pub const empty: Info = .{
        .features = .empty,
    };

    pub fn deinit(self: *Info, alloc: Allocator) void {
        self.features.deinit(alloc);
    }

    /// Grab the features into a new allocated slice. This is used by
    pub fn overlayFeatures(
        self: *const Info,
        alloc: Allocator,
    ) Allocator.Error![]renderer.Overlay.Feature {
        // The features from our internal state.
        const features = self.features.values();

        // For now we do a dumb copy since the features have no managed
        // memory.
        const result = try alloc.dupe(
            renderer.Overlay.Feature,
            features,
        );
        errdefer alloc.free(result);

        return result;
    }

    /// Draw the renderer info window.
    pub fn draw(
        self: *Info,
        alloc: Allocator,
        open: bool,
    ) void {
        if (!open) return;

        cimgui.c.ImGui_SeparatorText("Overlays");

        // Hyperlinks
        {
            var hyperlinks: bool = self.features.contains(.highlight_hyperlinks);
            _ = cimgui.c.ImGui_Checkbox("Overlay Hyperlinks", &hyperlinks);
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("When enabled, highlights OSC8 hyperlinks.");

            if (!hyperlinks) {
                _ = self.features.swapRemove(.highlight_hyperlinks);
            } else {
                self.features.put(
                    alloc,
                    .highlight_hyperlinks,
                    .highlight_hyperlinks,
                ) catch log.warn("error enabling hyperlink overlay feature", .{});
            }
        }
    }
};
