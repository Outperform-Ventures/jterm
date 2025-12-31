pub const build_options = @import("build_options");

pub const c = @cImport({
    @cInclude("dcimgui.h");
});

// OpenGL3 backend
pub extern fn ImGui_ImplOpenGL3_Init(glsl_version: ?[*:0]const u8) callconv(.c) bool;
pub extern fn ImGui_ImplOpenGL3_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplOpenGL3_NewFrame() callconv(.c) void;
pub extern fn ImGui_ImplOpenGL3_RenderDrawData(draw_data: *c.ImDrawData) callconv(.c) void;

// Metal backend
pub extern fn ImGui_ImplMetal_Init(device: *anyopaque) callconv(.c) bool;
pub extern fn ImGui_ImplMetal_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplMetal_NewFrame(render_pass_descriptor: *anyopaque) callconv(.c) void;
pub extern fn ImGui_ImplMetal_RenderDrawData(draw_data: *c.ImDrawData, command_buffer: *anyopaque, command_encoder: *anyopaque) callconv(.c) void;

// OSX
pub extern fn ImGui_ImplOSX_Init(*anyopaque) callconv(.c) bool;
pub extern fn ImGui_ImplOSX_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplOSX_NewFrame(*anyopaque) callconv(.c) void;

test {
    _ = c;
}
