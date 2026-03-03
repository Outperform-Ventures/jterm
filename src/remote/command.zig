const std = @import("std");

pub const Key = enum {
    action,
    close_tab,
    close_window,
    create_marker,
    detach_tab,
    detach_window,
    disable_ligatures,
    env,
    focus_tab,
    focus_window,
    get_colors,
    get_text,
    goto_layout,
    kitten,
    last_used_layout,
    launch,
    load_config,
    ls,
    new_tab,
    new_window,
    remove_marker,
    move_os_window,
    maximize_os_window,
    minimize_os_window,
    hide_os_window,
    snap_os_window,
    resize_os_window,
    resize_window,
    run,
    scroll_window,
    select_window,
    send_key,
    send_text,
    set_background_image,
    set_background_opacity,
    set_colors,
    set_enabled_layouts,
    set_font_size,
    set_spacing,
    set_tab_color,
    set_tab_title,
    set_user_vars,
    set_window_logo,
    set_window_title,
    signal_child,
};

pub const all = [_]Key{
    .action,
    .close_tab,
    .close_window,
    .create_marker,
    .detach_tab,
    .detach_window,
    .disable_ligatures,
    .env,
    .focus_tab,
    .focus_window,
    .get_colors,
    .get_text,
    .goto_layout,
    .kitten,
    .last_used_layout,
    .launch,
    .load_config,
    .ls,
    .new_tab,
    .new_window,
    .remove_marker,
    .move_os_window,
    .maximize_os_window,
    .minimize_os_window,
    .hide_os_window,
    .snap_os_window,
    .resize_os_window,
    .resize_window,
    .run,
    .scroll_window,
    .select_window,
    .send_key,
    .send_text,
    .set_background_image,
    .set_background_opacity,
    .set_colors,
    .set_enabled_layouts,
    .set_font_size,
    .set_spacing,
    .set_tab_color,
    .set_tab_title,
    .set_user_vars,
    .set_window_logo,
    .set_window_title,
    .signal_child,
};

pub fn parse(raw: []const u8) ?Key {
    if (std.mem.eql(u8, raw, "action")) return .action;
    if (std.mem.eql(u8, raw, "close-tab")) return .close_tab;
    if (std.mem.eql(u8, raw, "close-window")) return .close_window;
    if (std.mem.eql(u8, raw, "create-marker")) return .create_marker;
    if (std.mem.eql(u8, raw, "detach-tab")) return .detach_tab;
    if (std.mem.eql(u8, raw, "detach-window")) return .detach_window;
    if (std.mem.eql(u8, raw, "disable-ligatures")) return .disable_ligatures;
    if (std.mem.eql(u8, raw, "env")) return .env;
    if (std.mem.eql(u8, raw, "focus-tab")) return .focus_tab;
    if (std.mem.eql(u8, raw, "focus-window")) return .focus_window;
    if (std.mem.eql(u8, raw, "get-colors")) return .get_colors;
    if (std.mem.eql(u8, raw, "get-text")) return .get_text;
    if (std.mem.eql(u8, raw, "goto-layout")) return .goto_layout;
    if (std.mem.eql(u8, raw, "kitten")) return .kitten;
    if (std.mem.eql(u8, raw, "last-used-layout")) return .last_used_layout;
    if (std.mem.eql(u8, raw, "launch")) return .launch;
    if (std.mem.eql(u8, raw, "load-config")) return .load_config;
    if (std.mem.eql(u8, raw, "ls")) return .ls;
    if (std.mem.eql(u8, raw, "new-tab")) return .new_tab;
    if (std.mem.eql(u8, raw, "new-window")) return .new_window;
    if (std.mem.eql(u8, raw, "remove-marker")) return .remove_marker;
    if (std.mem.eql(u8, raw, "move-os-window")) return .move_os_window;
    if (std.mem.eql(u8, raw, "maximize-os-window")) return .maximize_os_window;
    if (std.mem.eql(u8, raw, "minimize-os-window")) return .minimize_os_window;
    if (std.mem.eql(u8, raw, "hide-os-window")) return .hide_os_window;
    if (std.mem.eql(u8, raw, "snap-os-window")) return .snap_os_window;
    if (std.mem.eql(u8, raw, "resize-os-window")) return .resize_os_window;
    if (std.mem.eql(u8, raw, "resize-window")) return .resize_window;
    if (std.mem.eql(u8, raw, "run")) return .run;
    if (std.mem.eql(u8, raw, "scroll-window")) return .scroll_window;
    if (std.mem.eql(u8, raw, "select-window")) return .select_window;
    if (std.mem.eql(u8, raw, "send-key")) return .send_key;
    if (std.mem.eql(u8, raw, "send-text")) return .send_text;
    if (std.mem.eql(u8, raw, "set-background-image")) return .set_background_image;
    if (std.mem.eql(u8, raw, "set-background-opacity")) return .set_background_opacity;
    if (std.mem.eql(u8, raw, "set-colors")) return .set_colors;
    if (std.mem.eql(u8, raw, "set-enabled-layouts")) return .set_enabled_layouts;
    if (std.mem.eql(u8, raw, "set-font-size")) return .set_font_size;
    if (std.mem.eql(u8, raw, "set-spacing")) return .set_spacing;
    if (std.mem.eql(u8, raw, "set-tab-color")) return .set_tab_color;
    if (std.mem.eql(u8, raw, "set-tab-title")) return .set_tab_title;
    if (std.mem.eql(u8, raw, "set-user-vars")) return .set_user_vars;
    if (std.mem.eql(u8, raw, "set-window-logo")) return .set_window_logo;
    if (std.mem.eql(u8, raw, "set-window-title")) return .set_window_title;
    if (std.mem.eql(u8, raw, "signal-child")) return .signal_child;
    return null;
}

pub fn name(cmd: Key) []const u8 {
    return switch (cmd) {
        .action => "action",
        .close_tab => "close-tab",
        .close_window => "close-window",
        .create_marker => "create-marker",
        .detach_tab => "detach-tab",
        .detach_window => "detach-window",
        .disable_ligatures => "disable-ligatures",
        .env => "env",
        .focus_tab => "focus-tab",
        .focus_window => "focus-window",
        .get_colors => "get-colors",
        .get_text => "get-text",
        .goto_layout => "goto-layout",
        .kitten => "kitten",
        .last_used_layout => "last-used-layout",
        .launch => "launch",
        .load_config => "load-config",
        .ls => "ls",
        .new_tab => "new-tab",
        .new_window => "new-window",
        .remove_marker => "remove-marker",
        .move_os_window => "move-os-window",
        .maximize_os_window => "maximize-os-window",
        .minimize_os_window => "minimize-os-window",
        .hide_os_window => "hide-os-window",
        .snap_os_window => "snap-os-window",
        .resize_os_window => "resize-os-window",
        .resize_window => "resize-window",
        .run => "run",
        .scroll_window => "scroll-window",
        .select_window => "select-window",
        .send_key => "send-key",
        .send_text => "send-text",
        .set_background_image => "set-background-image",
        .set_background_opacity => "set-background-opacity",
        .set_colors => "set-colors",
        .set_enabled_layouts => "set-enabled-layouts",
        .set_font_size => "set-font-size",
        .set_spacing => "set-spacing",
        .set_tab_color => "set-tab-color",
        .set_tab_title => "set-tab-title",
        .set_user_vars => "set-user-vars",
        .set_window_logo => "set-window-logo",
        .set_window_title => "set-window-title",
        .signal_child => "signal-child",
    };
}

test "parse supports all kitty command names" {
    const testing = std.testing;
    inline for (all) |cmd| {
        const parsed = parse(name(cmd));
        try testing.expect(parsed != null);
        try testing.expectEqual(cmd, parsed.?);
    }
}

test "parse rejects unknown command names" {
    const testing = std.testing;
    try testing.expect(parse("no-such-command") == null);
    try testing.expect(parse("focus_window") == null);
}
