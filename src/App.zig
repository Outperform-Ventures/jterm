//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const Surface = @import("Surface.zig");
const input = @import("input.zig");
const configpkg = @import("config.zig");
const Config = configpkg.Config;
const BlockingQueue = @import("datastruct/main.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const remote = @import("remote/main.zig");
const terminal = @import("terminal/main.zig");
const X25519 = std.crypto.dh.X25519;

const log = std.log.scoped(.app);

const SurfaceList = std.ArrayListUnmanaged(*apprt.Surface);
const SurfaceMetaMap = std.AutoHashMapUnmanaged(*Surface, RemoteSurfaceMeta);

const RemoteEnvPair = remote.matcher.EnvPair;

const RemoteSurfaceMeta = struct {
    id: u64,
    last_focus: u64 = 0,
    env_tags: std.ArrayListUnmanaged(RemoteEnvPair) = .{},
    user_vars: std.ArrayListUnmanaged(RemoteEnvPair) = .{},
    markers: std.ArrayListUnmanaged([]u8) = .{},
    current_layout: ?[]u8 = null,
    last_layout: ?[]u8 = null,
    enabled_layouts: ?[]u8 = null,
    tab_color: ?[]u8 = null,
    window_logo: ?[]u8 = null,
    background_image: ?[]u8 = null,
    spacing: ?[]u8 = null,
    disable_ligatures: bool = false,
    background_opacity: ?f32 = null,
    font_size_override: ?f32 = null,

    fn deinit(self: *RemoteSurfaceMeta, alloc: Allocator) void {
        for (self.env_tags.items) |pair| {
            alloc.free(pair.key);
            alloc.free(pair.value);
        }
        self.env_tags.deinit(alloc);
        for (self.user_vars.items) |pair| {
            alloc.free(pair.key);
            alloc.free(pair.value);
        }
        self.user_vars.deinit(alloc);
        for (self.markers.items) |marker| alloc.free(marker);
        self.markers.deinit(alloc);
        if (self.current_layout) |v| alloc.free(v);
        if (self.last_layout) |v| alloc.free(v);
        if (self.enabled_layouts) |v| alloc.free(v);
        if (self.tab_color) |v| alloc.free(v);
        if (self.window_logo) |v| alloc.free(v);
        if (self.background_image) |v| alloc.free(v);
        if (self.spacing) |v| alloc.free(v);
        self.* = undefined;
    }

    fn setEnvTag(
        self: *RemoteSurfaceMeta,
        alloc: Allocator,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!void {
        try setPairValue(&self.env_tags, alloc, key, value);
    }

    fn removeEnvTag(self: *RemoteSurfaceMeta, alloc: Allocator, key: []const u8) bool {
        return removePair(&self.env_tags, alloc, key);
    }

    fn setUserVar(
        self: *RemoteSurfaceMeta,
        alloc: Allocator,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!void {
        try setPairValue(&self.user_vars, alloc, key, value);
    }

    fn removeUserVar(self: *RemoteSurfaceMeta, alloc: Allocator, key: []const u8) bool {
        return removePair(&self.user_vars, alloc, key);
    }

    fn addMarker(
        self: *RemoteSurfaceMeta,
        alloc: Allocator,
        marker: []const u8,
    ) Allocator.Error!void {
        for (self.markers.items) |v| {
            if (std.mem.eql(u8, v, marker)) return;
        }
        try self.markers.append(alloc, try alloc.dupe(u8, marker));
    }

    fn removeMarker(self: *RemoteSurfaceMeta, alloc: Allocator, marker: []const u8) bool {
        var i: usize = 0;
        while (i < self.markers.items.len) {
            if (!std.mem.eql(u8, self.markers.items[i], marker)) {
                i += 1;
                continue;
            }

            alloc.free(self.markers.items[i]);
            _ = self.markers.swapRemove(i);
            return true;
        }

        return false;
    }

    fn clearMarkers(self: *RemoteSurfaceMeta, alloc: Allocator) void {
        for (self.markers.items) |marker| alloc.free(marker);
        self.markers.clearRetainingCapacity();
    }

    fn setCurrentLayout(self: *RemoteSurfaceMeta, alloc: Allocator, value: []const u8) Allocator.Error!void {
        if (self.current_layout) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
            self.last_layout = try replaceOwnedString(alloc, self.last_layout, existing);
            self.current_layout = try replaceOwnedString(alloc, self.current_layout, value);
            return;
        }

        self.current_layout = try alloc.dupe(u8, value);
    }

    fn restoreLastLayout(self: *RemoteSurfaceMeta, alloc: Allocator) Allocator.Error!bool {
        const previous = self.last_layout orelse return false;
        const current = self.current_layout;
        self.current_layout = try alloc.dupe(u8, previous);
        alloc.free(previous);
        self.last_layout = if (current) |v| try alloc.dupe(u8, v) else null;
        if (current) |v| alloc.free(v);
        return true;
    }

    fn setEnabledLayouts(self: *RemoteSurfaceMeta, alloc: Allocator, value: []const u8) Allocator.Error!void {
        self.enabled_layouts = try replaceOwnedString(alloc, self.enabled_layouts, value);
    }

    fn setTabColor(self: *RemoteSurfaceMeta, alloc: Allocator, value: []const u8) Allocator.Error!void {
        self.tab_color = try replaceOwnedString(alloc, self.tab_color, value);
    }

    fn setWindowLogo(self: *RemoteSurfaceMeta, alloc: Allocator, value: []const u8) Allocator.Error!void {
        self.window_logo = try replaceOwnedString(alloc, self.window_logo, value);
    }

    fn setBackgroundImage(self: *RemoteSurfaceMeta, alloc: Allocator, value: []const u8) Allocator.Error!void {
        self.background_image = try replaceOwnedString(alloc, self.background_image, value);
    }

    fn setSpacing(self: *RemoteSurfaceMeta, alloc: Allocator, value: []const u8) Allocator.Error!void {
        self.spacing = try replaceOwnedString(alloc, self.spacing, value);
    }
};

fn replaceOwnedString(
    alloc: Allocator,
    current: ?[]u8,
    value: []const u8,
) Allocator.Error!?[]u8 {
    const duped = try alloc.dupe(u8, value);
    if (current) |v| alloc.free(v);
    return duped;
}

fn setPairValue(
    list: *std.ArrayListUnmanaged(RemoteEnvPair),
    alloc: Allocator,
    key: []const u8,
    value: []const u8,
) Allocator.Error!void {
    for (list.items) |*pair| {
        if (!std.mem.eql(u8, pair.key, key)) continue;
        const new_value = try alloc.dupe(u8, value);
        alloc.free(pair.value);
        pair.value = new_value;
        return;
    }

    try list.append(alloc, .{
        .key = try alloc.dupe(u8, key),
        .value = try alloc.dupe(u8, value),
    });
}

fn removePair(
    list: *std.ArrayListUnmanaged(RemoteEnvPair),
    alloc: Allocator,
    key: []const u8,
) bool {
    var i: usize = 0;
    while (i < list.items.len) {
        if (!std.mem.eql(u8, list.items[i].key, key)) {
            i += 1;
            continue;
        }

        alloc.free(list.items[i].key);
        alloc.free(list.items[i].value);
        _ = list.swapRemove(i);
        return true;
    }

    return false;
}

const PendingRemoteLaunch = struct {
    surface_id: u64,
    title: ?[]u8 = null,
    window_state: remote.launch.Parsed.OsWindowState = .normal,
    send_text: ?[]u8 = null,
    env_tags: std.ArrayListUnmanaged(RemoteEnvPair) = .{},

    fn deinit(self: *PendingRemoteLaunch, alloc: Allocator) void {
        if (self.title) |title| alloc.free(title);
        if (self.send_text) |text| alloc.free(text);
        for (self.env_tags.items) |pair| {
            alloc.free(pair.key);
            alloc.free(pair.value);
        }
        self.env_tags.deinit(alloc);
        self.* = undefined;
    }

    fn appendEnvTag(
        self: *PendingRemoteLaunch,
        alloc: Allocator,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!void {
        try self.env_tags.append(alloc, .{
            .key = try alloc.dupe(u8, key),
            .value = try alloc.dupe(u8, value),
        });
    }
};

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

/// Stable metadata for each active surface for remote-control addressing.
surface_meta: SurfaceMetaMap,

/// Pending launch directives keyed by the next expected surface id.
pending_remote_launches: std.ArrayListUnmanaged(PendingRemoteLaunch),

/// This is true if the app that Ghostty is in is focused. This may
/// mean that no surfaces (terminals) are focused but the app is still
/// focused, i.e. may an about window. On macOS, this concept is known
/// as the "active" app while focused windows are known as the
/// "main" window.
///
/// This is used to determine if keyboard shortcuts that are non-global
/// should be processed. If the app is not focused, then we don't want
/// to process keyboard shortcuts that are not global.
///
/// This defaults to true since we assume that the app is focused when
/// Ghostty is initialized but a well behaved apprt should call
/// focusEvent to set this to the correct value right away.
focused: bool = true,

/// The last focused surface. This surface may not be valid;
/// you must always call hasSurface to validate it.
focused_surface: ?*Surface = null,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: Mailbox.Queue,

/// Mailbox wrapper that wakes the runtime event loop. Set only once the
/// runtime app has initialized.
remote_mailbox: ?Mailbox = null,

/// The set of font GroupCache instances shared by surfaces with the
/// same font configuration.
font_grid_set: font.SharedGridSet,

// Used to rate limit desktop notifications. Some platforms (notably macOS) will
// run out of resources if desktop notifications are sent too fast and the OS
// will kill Ghostty.
last_notification_time: ?std.time.Instant = null,
last_notification_digest: u64 = 0,

/// The conditional state of the configuration. See the equivalent field
/// in the Surface struct for more information. In this case, this applies
/// to the app-level config and as a default for new surfaces.
config_conditional_state: configpkg.ConditionalState,

/// Set to false once we've created at least one surface. This
/// never goes true again. This can be used by surfaces to determine
/// if they are the first surface.
first: bool = true,

/// Next stable remote-control surface id.
next_surface_id: u64 = 1,

/// Monotonic counter used to compute "recent" ranks.
focus_epoch: u64 = 1,

/// Socket-based remote control server.
remote_server: ?remote.server.Server = null,

/// Whether remote control is enabled by configuration.
remote_control_enabled: bool = false,

/// Optional password required for remote control requests.
remote_control_password: ?[]u8 = null,

/// X25519 keypair used for encrypted remote-control requests.
remote_keypair: ?X25519.KeyPair = null,

/// Public key string encoded in kitty-compatible format.
remote_public_key: ?[]u8 = null,

pub const CreateError = Allocator.Error || font.SharedGridSet.InitError;

/// Create a new app instance. This returns a stable pointer to the app
/// instance which is required for callbacks.
pub fn create(alloc: Allocator) CreateError!*App {
    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    try app.init(alloc);
    return app;
}

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
///
/// After calling this function, well behaved apprts should then call
/// `focusEvent` to set the initial focus state of the app.
pub fn init(
    self: *App,
    alloc: Allocator,
) CreateError!void {
    var font_grid_set = try font.SharedGridSet.init(alloc);
    errdefer font_grid_set.deinit();

    self.* = .{
        .alloc = alloc,
        .surfaces = .{},
        .surface_meta = .{},
        .pending_remote_launches = .{},
        .mailbox = .{},
        .font_grid_set = font_grid_set,
        .config_conditional_state = .{},
    };
}

pub fn deinit(self: *App) void {
    self.stopRemoteControl();

    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);
    for (self.pending_remote_launches.items) |*pending| pending.deinit(self.alloc);
    self.pending_remote_launches.deinit(self.alloc);
    var meta_it = self.surface_meta.iterator();
    while (meta_it.next()) |entry| entry.value_ptr.deinit(self.alloc);
    self.surface_meta.deinit(self.alloc);
    if (self.remote_control_password) |password| self.alloc.free(password);
    if (self.remote_public_key) |public_key| self.alloc.free(public_key);

    // Clean up our font group cache
    // We should have zero items in the grid set at this point because
    // destroy only gets called when the app is shutting down and this
    // should gracefully close all surfaces.
    assert(self.font_grid_set.count() == 0);
    self.font_grid_set.deinit();
}

pub fn destroy(self: *App) void {
    // Deinitialize the app
    self.deinit();

    // Free the app memory
    self.alloc.destroy(self);
}

/// Tick ticks the app loop. This will drain our mailbox and process those
/// events. This should be called by the application runtime on every loop
/// tick.
pub fn tick(self: *App, rt_app: *apprt.App) !void {
    // Drain our mailbox
    try self.drainMailbox(rt_app);
}

/// Update whether remote control should be enabled.
pub fn setRemoteControlEnabled(self: *App, enabled: bool) void {
    self.remote_control_enabled = enabled;
}

pub fn setRemoteControlPassword(self: *App, password: ?[]const u8) Allocator.Error!void {
    if (self.remote_control_password) |existing| {
        self.alloc.free(existing);
        self.remote_control_password = null;
    }
    if (password) |value| {
        if (value.len == 0) return;
        self.remote_control_password = try self.alloc.dupe(u8, value);
    }
}

/// Start the unix socket remote-control server.
pub fn startRemoteControl(self: *App, rt_app: *apprt.App) !void {
    if (!self.remote_control_enabled) return;
    if (self.remote_server != null) return;
    if (!std.net.has_unix_sockets) return;

    if (self.remote_keypair == null) {
        const keypair = X25519.KeyPair.generate();
        self.remote_keypair = keypair;
        if (self.remote_public_key == null) {
            self.remote_public_key = try remote.protocol.encodeKittyPublicKey(
                self.alloc,
                1,
                keypair.public_key,
            );
        }
    }

    const socket_path = socket_path: {
        const target = if (std.posix.getenv("JTERM_LISTEN_ON")) |v|
            std.mem.sliceTo(v, 0)
        else
            "unix:/tmp/jterm.sock";

        const path = try remote.transport.unixPathFromTarget(target);
        break :socket_path try std.heap.page_allocator.dupe(u8, path);
    };
    defer std.heap.page_allocator.free(socket_path);

    const server = try remote.server.Server.init(
        std.heap.page_allocator,
        .{
            .userdata = self,
            .submitFn = submitRemoteRequest,
        },
        socket_path,
    );
    self.remote_server = server;
    errdefer {
        if (self.remote_server) |*s| s.deinit();
        self.remote_server = null;
    }

    try self.remote_server.?.start();
    self.remote_mailbox = .{ .rt_app = rt_app, .mailbox = &self.mailbox };

    log.info("remote control listening on unix:{s}", .{self.remote_server.?.socket_path});
}

/// Stop the remote-control server if it is running.
pub fn stopRemoteControl(self: *App) void {
    self.remote_mailbox = null;

    if (self.remote_server) |*server| {
        server.deinit();
        self.remote_server = null;
    }
}

/// Update the configuration associated with the app. This can only be
/// called from the main thread. The caller owns the config memory. The
/// memory can be freed immediately when this returns.
pub fn updateConfig(self: *App, rt_app: *apprt.App, config: *const Config) !void {
    // Go through and update all of the surface configurations.
    for (self.surfaces.items) |surface| {
        try surface.core().handleMessage(.{ .change_config = config });
    }

    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    // We only apply this to the app-level config because the surface
    // config applies its own conditional state.
    var applied_: ?configpkg.Config = config.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (applied_) |*c| c.deinit();
    const applied: *const configpkg.Config = if (applied_) |*c| c else config;

    const remote_changed = self.remote_control_enabled != applied.@"allow-remote-control";
    self.remote_control_enabled = applied.@"allow-remote-control";
    try self.setRemoteControlPassword(applied.@"remote-control-password");
    if (remote_changed) {
        if (self.remote_control_enabled) {
            try self.startRemoteControl(rt_app);
        } else {
            self.stopRemoteControl();
        }
    }

    // Notify the apprt that the app has changed configuration.
    _ = try rt_app.performAction(
        .app,
        .config_change,
        .{ .config = applied },
    );
}

/// Add an initialized surface. This is really only for the runtime
/// implementations to call and should NOT be called by general app users.
/// The surface must be from the pool.
pub fn addSurface(
    self: *App,
    rt_surface: *apprt.Surface,
) Allocator.Error!void {
    try self.surfaces.append(self.alloc, rt_surface);
    errdefer _ = self.surfaces.pop();

    const assigned_id = self.next_surface_id;
    const core_surface = rt_surface.core();
    try self.surface_meta.put(self.alloc, core_surface, .{
        .id = assigned_id,
    });
    self.next_surface_id += 1;
    errdefer {
        if (self.surface_meta.fetchRemove(core_surface)) |removed| {
            var meta = removed.value;
            meta.deinit(self.alloc);
        }
    }

    try self.applyPendingRemoteLaunch(rt_surface, assigned_id);

    // Since we have non-zero surfaces, we can cancel the quit timer.
    // It is up to the apprt if there is a quit timer at all and if it
    // should be canceled.
    _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .stop,
    ) catch |err| {
        log.warn("error stopping quit timer err={}", .{err});
    };
}

/// Delete the surface from the known surface list. This will NOT call the
/// destructor or free the memory.
pub fn deleteSurface(self: *App, rt_surface: *apprt.Surface) void {
    if (self.surface_meta.fetchRemove(rt_surface.core())) |removed| {
        var meta = removed.value;
        meta.deinit(self.alloc);
    }

    // If this surface is the focused surface then we need to clear it.
    // There was a bug where we relied on hasSurface to return false and
    // just let focused surface be but the allocator was reusing addresses
    // after free and giving false positives, so we must clear it.
    if (self.focused_surface) |focused| {
        if (focused == rt_surface.core()) {
            self.focused_surface = null;
        }
    }

    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        if (self.surfaces.items[i] == rt_surface) {
            _ = self.surfaces.swapRemove(i);
            continue;
        }

        i += 1;
    }

    // If we have no surfaces, we can start the quit timer. It is up to the
    // apprt to determine if this is necessary.
    if (self.surfaces.items.len == 0) _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .start,
    ) catch |err| {
        log.warn("error starting quit timer err={}", .{err});
    };
}

/// The last focused surface. This is only valid while on the main thread
/// before tick is called.
pub fn focusedSurface(self: *const App) ?*Surface {
    const surface = self.focused_surface orelse return null;
    if (!self.hasSurface(surface)) return null;
    return surface;
}

/// Returns true if confirmation is needed to quit the app. It is up to
/// the apprt to call this.
pub fn needsConfirmQuit(self: *const App) bool {
    for (self.surfaces.items) |v| {
        if (v.core().needsConfirmQuit()) return true;
    }

    return false;
}

/// Drain the mailbox.
fn drainMailbox(self: *App, rt_app: *apprt.App) !void {
    while (self.mailbox.pop()) |message| {
        if (comptime std.log.logEnabled(.debug, .app)) {
            switch (message) {
                // these tend to be way too verbose for normal debugging
                .redraw_surface => {},
                else => log.debug("mailbox message={t}", .{message}),
            }
        }
        switch (message) {
            .open_config => try self.performAction(rt_app, .open_config),
            .new_window => |msg| try self.newWindow(rt_app, msg),
            .close => |surface| self.closeSurface(surface),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
            .redraw_surface => |surface| try self.redrawSurface(rt_app, surface),
            .remote_request => |req| self.handleRemoteRequest(rt_app, req),

            // If we're quitting, then we set the quit flag and stop
            // draining the mailbox immediately. This lets us defer
            // mailbox processing to the next tick so that the apprt
            // can try to quit as quickly as possible.
            .quit => {
                log.info("quit message received, short circuiting mailbox drain", .{});
                try self.performAction(rt_app, .quit);
                return;
            },
        }
    }
}

fn submitRemoteRequest(ctx: *anyopaque, req: *remote.server.PendingRequest) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    const mailbox = self.remote_mailbox orelse return false;
    return mailbox.push(.{ .remote_request = req }, .{ .forever = {} }) > 0;
}

const RemoteCommandError = error{
    UnsupportedCommand,
    NoSurfaces,
    NoMatch,
    AmbiguousMatch,
    InvalidArguments,
    InvalidMatchExpression,
    ActionFailed,
};

const RemoteSelectMode = enum {
    single,
    many,
};

const RemoteTextExtent = enum {
    selection,
    screen,
    all,
};

fn handleRemoteRequest(
    self: *App,
    rt_app: *apprt.App,
    pending: *remote.server.PendingRequest,
) void {
    const alloc = std.heap.page_allocator;

    const response = response: {
        var parsed_wire = remote.protocol.parseWireRequest(alloc, pending.request_json) catch |err| {
            const message = switch (err) {
                error.MessageTooLarge => "request message is too large",
                error.MissingCommand => "request is missing `cmd`",
                else => "invalid request payload",
            };
            break :response remote.protocol.encodeError(alloc, message) catch alloc.dupe(
                u8,
                "{\"ok\":false,\"error\":\"invalid request\"}",
            ) catch return;
        };
        defer parsed_wire.deinit();

        var decrypted_request: ?remote.protocol.ParsedRequest = null;
        defer if (decrypted_request) |*parsed| parsed.deinit();

        const request = request: {
            switch (parsed_wire) {
                .plain => |plain| break :request plain.value,
                .encrypted => |encrypted| {
                    const keypair = self.remote_keypair orelse {
                        break :response remote.protocol.encodeError(alloc, "remote-control authorization failed") catch alloc.dupe(
                            u8,
                            "{\"ok\":false,\"error\":\"remote-control authorization failed\"}",
                        ) catch return;
                    };

                    decrypted_request = remote.protocol.decryptRequestEnvelope(
                        alloc,
                        encrypted,
                        keypair.secret_key,
                    ) catch {
                        break :response remote.protocol.encodeError(alloc, "remote-control authorization failed") catch alloc.dupe(
                            u8,
                            "{\"ok\":false,\"error\":\"remote-control authorization failed\"}",
                        ) catch return;
                    };
                    break :request decrypted_request.?.value;
                },
            }
        };

        if (self.remote_control_password) |required_password| {
            const provided_password = request.password orelse "";
            if (!std.mem.eql(u8, required_password, provided_password)) {
                break :response remote.protocol.encodeError(alloc, "remote-control authorization failed") catch alloc.dupe(
                    u8,
                    "{\"ok\":false,\"error\":\"remote-control authorization failed\"}",
                ) catch return;
            }
        }

        const encoded = self.dispatchRemoteCommand(
            rt_app,
            request,
            alloc,
        ) catch |err| {
            if (err == error.NoMatch and request.ignore_no_match) {
                break :response remote.protocol.encodeOk(alloc, .{
                    .ignored = true,
                    .reason = "no match",
                }) catch alloc.dupe(
                    u8,
                    "{\"ok\":true,\"data\":{\"ignored\":true,\"reason\":\"no match\"}}",
                ) catch return;
            }
            const message = switch (err) {
                error.UnsupportedCommand => "unsupported remote-control command",
                error.NoSurfaces => "no surfaces are available",
                error.NoMatch => "no target matched the request",
                error.AmbiguousMatch => "match expression resolved to multiple targets",
                error.InvalidArguments => "invalid command arguments",
                error.InvalidMatchExpression => "invalid match expression",
                error.ActionFailed => "requested action failed",
                else => "remote-control command failed",
            };
            break :response remote.protocol.encodeError(alloc, message) catch alloc.dupe(
                u8,
                "{\"ok\":false,\"error\":\"remote-control command failed\"}",
            ) catch return;
        };

        if (request.no_response) {
            alloc.free(encoded);
            break :response alloc.dupe(u8, "") catch return;
        }

        break :response encoded;
    };

    pending.complete(response);
}

fn dispatchRemoteCommand(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const cmd = remote.command.parse(request.cmd) orelse return error.UnsupportedCommand;
    return switch (cmd) {
        .ls => try self.remoteList(alloc),
        .new_tab => try self.remoteNewTab(rt_app, request, alloc),
        .new_window, .launch => try self.remoteNewWindow(rt_app, request, alloc),
        .close_window => try self.remoteCloseWindow(rt_app, request, alloc),
        .close_tab => try self.remoteCloseTab(rt_app, request, alloc),
        .focus_window, .select_window => try self.remoteFocusWindow(rt_app, request, alloc),
        .focus_tab => try self.remoteFocusTab(rt_app, request, alloc),
        .set_window_title => try self.remoteSetWindowTitle(rt_app, request, alloc),
        .set_tab_title => try self.remoteSetTabTitle(rt_app, request, alloc),
        .send_text => try self.remoteSendText(request, alloc),
        .send_key => try self.remoteSendKey(request, alloc),
        .action => try self.remoteAction(rt_app, request, alloc),
        .env => try self.remoteEnv(request, alloc),
        .set_user_vars => try self.remoteSetUserVars(request, alloc),
        .create_marker => try self.remoteCreateMarker(request, alloc),
        .remove_marker => try self.remoteRemoveMarker(request, alloc),
        .move_os_window => try self.remoteMoveOsWindow(rt_app, request, alloc),
        .maximize_os_window => try self.remoteMaximizeOsWindow(rt_app, request, alloc),
        .minimize_os_window => try self.remoteMinimizeOsWindow(rt_app, request, alloc),
        .hide_os_window => try self.remoteHideOsWindow(rt_app, request, alloc),
        .snap_os_window => try self.remoteSnapOsWindow(rt_app, request, alloc),
        .run => try self.remoteRun(request, alloc),
        .scroll_window => try self.remoteScrollWindow(request, alloc),
        .resize_window => try self.remoteResizeWindow(request, alloc),
        .resize_os_window => try self.remoteResizeOsWindow(rt_app, request, alloc),
        .set_font_size => try self.remoteSetFontSize(request, alloc),
        .set_background_opacity => try self.remoteSetBackgroundOpacity(rt_app, request, alloc),
        .set_background_image => try self.remoteSetBackgroundImage(request, alloc),
        .set_tab_color => try self.remoteSetTabColor(request, alloc),
        .set_window_logo => try self.remoteSetWindowLogo(request, alloc),
        .set_spacing => try self.remoteSetSpacing(request, alloc),
        .set_enabled_layouts => try self.remoteSetEnabledLayouts(request, alloc),
        .goto_layout => try self.remoteGotoLayout(request, alloc),
        .last_used_layout => try self.remoteLastUsedLayout(request, alloc),
        .detach_tab => try self.remoteDetachTab(rt_app, request, alloc),
        .detach_window => try self.remoteDetachWindow(rt_app, request, alloc),
        .get_colors => try self.remoteGetColors(alloc),
        .set_colors => try self.remoteSetColors(request, alloc),
        .get_text => try self.remoteGetText(request, alloc),
        .disable_ligatures => try self.remoteDisableLigatures(request, alloc),
        .load_config => try self.remoteLoadConfig(rt_app, alloc),
        .signal_child => try self.remoteSignalChild(request, alloc),
        .kitten => try self.remoteKitten(request, alloc),
    };
}

fn remoteList(
    self: *const App,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const Entry = struct {
        id: u64,
        pid: ?u64,
        num: u64,
        focused: bool,
        active: bool,
        recent: u64,
        title: ?[]const u8,
        cmdline: ?[]const u8,
        cwd: ?[]const u8,
        env: []const RemoteEnvPair,
        vars: []const RemoteEnvPair,
        markers: []const []const u8,
        layout: ?[]const u8,
        enabled_layouts: ?[]const u8,
    };

    const WindowEntry = struct {
        id: u64,
        pid: ?u64,
        title: ?[]const u8,
        cwd: ?[]const u8,
        cmdline: ?[]const []const u8,
        env: []const RemoteEnvPair,
        user_vars: []const RemoteEnvPair,
        is_active: bool,
        is_focused: bool,
    };

    const TabEntry = struct {
        id: u64,
        title: []const u8,
        is_active: bool,
        is_focused: bool,
        windows: []const WindowEntry,
    };

    const OsWindowEntry = struct {
        id: u64,
        is_active: bool,
        is_focused: bool,
        tabs: []const TabEntry,
    };

    var entries: std.ArrayList(Entry) = .empty;
    var windows: std.ArrayList(WindowEntry) = .empty;
    var owned_titles: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |entry| if (entry.cwd) |cwd| alloc.free(cwd);
        for (owned_titles.items) |title| alloc.free(title);
        entries.deinit(alloc);
        windows.deinit(alloc);
        owned_titles.deinit(alloc);
    }

    const focused = self.focusedSurface();
    const empty_pairs: []const RemoteEnvPair = &.{};
    for (self.surfaces.items) |rt_surface| {
        const core = rt_surface.core();
        const meta = self.surface_meta.get(core) orelse continue;
        const is_focused = focused != null and focused.? == core;
        const cwd = core.pwd(alloc) catch null;
        const title = title: {
            if (try remoteSurfaceWindowTitleOwned(rt_surface, alloc)) |owned| {
                try owned_titles.append(alloc, owned);
                break :title @as(?[]const u8, owned);
            }
            if (rt_surface.getTitle()) |v| break :title std.mem.sliceTo(v, 0);
            break :title null;
        };

        try entries.append(alloc, .{
            .id = meta.id,
            .pid = null,
            .num = meta.id,
            .focused = is_focused,
            .active = self.focused,
            .recent = self.recentRank(meta.last_focus),
            .title = title,
            .cmdline = null,
            .cwd = cwd,
            .env = meta.env_tags.items,
            .vars = meta.user_vars.items,
            .markers = meta.markers.items,
            .layout = meta.current_layout,
            .enabled_layouts = meta.enabled_layouts,
        });

        try windows.append(alloc, .{
            .id = meta.id,
            .pid = null,
            .title = title,
            .cwd = cwd,
            .cmdline = null,
            .env = meta.env_tags.items,
            .user_vars = meta.user_vars.items,
            .is_active = is_focused,
            .is_focused = is_focused,
        });
    }

    if (windows.items.len == 0) {
        try windows.append(alloc, .{
            .id = 1,
            .pid = null,
            .title = "jterm",
            .cwd = null,
            .cmdline = null,
            .env = empty_pairs,
            .user_vars = empty_pairs,
            .is_active = self.focused,
            .is_focused = self.focused,
        });
    }

    const tabs = [_]TabEntry{
        .{
            .id = 1,
            .title = "jterm",
            .is_active = true,
            .is_focused = true,
            .windows = windows.items,
        },
    };
    const os_windows = [_]OsWindowEntry{
        .{
            .id = 1,
            .is_active = self.focused,
            .is_focused = self.focused,
            .tabs = tabs[0..],
        },
    };

    return remote.protocol.encodeOk(alloc, .{
        .surfaces = entries.items,
        .os_windows = os_windows[0..],
        .kitty_public_key = self.remote_public_key,
    });
}

fn remoteNewWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    var parsed_launch_: ?remote.launch.Parsed = null;
    defer if (parsed_launch_) |*parsed_launch| parsed_launch.deinit(alloc);

    if (std.mem.eql(u8, request.cmd, "launch")) {
        parsed_launch_ = remote.launch.parseArgs(alloc, request.argv) catch |err| switch (err) {
            error.MissingValue,
            error.InvalidValue,
            error.InvalidEnv,
            error.UnsupportedOption,
            => return error.InvalidArguments,
            error.OutOfMemory => return error.OutOfMemory,
        };
    } else if (request.argv.len > 0) {
        return error.InvalidArguments;
    }

    const expected_surface_id = self.next_surface_id;

    if (self.surfaces.items.len == 0) {
        try self.newWindow(rt_app, .{ .parent = null });
        if (parsed_launch_) |parsed_launch| {
            const created_surface = self.rtSurfaceByRemoteId(expected_surface_id) orelse return error.ActionFailed;
            try self.applyLaunchDirectives(rt_app, created_surface, parsed_launch, alloc);
        }
        return remote.protocol.encodeOk(alloc, .{
            .created = @as(u32, 1),
            .id = expected_surface_id,
        });
    }

    var targets = try self.selectRemoteTargets(alloc, request, .single);
    defer alloc.free(targets);

    const parent = if (targets.len > 0) targets[0].core() else null;
    try self.newWindow(rt_app, .{ .parent = parent });
    if (parsed_launch_) |parsed_launch| {
        const created_surface = self.rtSurfaceByRemoteId(expected_surface_id) orelse return error.ActionFailed;
        try self.applyLaunchDirectives(rt_app, created_surface, parsed_launch, alloc);
    }

    return remote.protocol.encodeOk(alloc, .{
        .created = @as(u32, 1),
        .id = expected_surface_id,
    });
}

fn applyLaunchDirectives(
    self: *App,
    rt_app: *apprt.App,
    rt_surface: *apprt.Surface,
    parsed_launch: remote.launch.Parsed,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)!void {
    const meta = self.surface_meta.getPtr(rt_surface.core()) orelse return error.ActionFailed;

    for (parsed_launch.env) |pair| {
        try meta.setEnvTag(self.alloc, pair.key, pair.value);
    }

    if (parsed_launch.title) |title| {
        const title_z = try alloc.dupeZ(u8, title);
        defer alloc.free(title_z);

        const ok = rt_app.performAction(
            .{ .surface = rt_surface.core() },
            .set_window_title,
            .{ .title = title_z },
        ) catch return error.ActionFailed;
        if (!ok) return error.ActionFailed;
    }

    try applyLaunchWindowState(rt_app, rt_surface, parsed_launch.os_window_state);

    const launch_text = try remote.launch.buildLaunchText(alloc, parsed_launch);
    defer if (launch_text) |text| alloc.free(text);
    if (launch_text) |text| {
        rt_surface.core().remoteInputCallback(text) catch return error.ActionFailed;
    }
}

fn applyLaunchWindowState(
    rt_app: *apprt.App,
    rt_surface: *apprt.Surface,
    state: remote.launch.Parsed.OsWindowState,
) RemoteCommandError!void {
    const control: ?apprt.action.OsWindowControl = switch (state) {
        .normal => null,
        .maximized => .{
            .operation = .maximize,
            .monitor = 0,
        },
        .minimized => .{
            .operation = .minimize,
            .monitor = 0,
        },
        .hidden => .{
            .operation = .hide,
            .monitor = 0,
        },
    };

    if (control) |v| {
        const ok = rt_app.performAction(
            .{ .surface = rt_surface.core() },
            .os_window_control,
            v,
        ) catch return error.ActionFailed;
        if (!ok) return error.ActionFailed;
    }
}

fn rtSurfaceByRemoteId(self: *const App, id: u64) ?*apprt.Surface {
    for (self.surfaces.items) |rt_surface| {
        const meta = self.surface_meta.get(rt_surface.core()) orelse continue;
        if (meta.id == id) return rt_surface;
    }
    return null;
}

fn remoteNewTab(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len > 0) return error.InvalidArguments;

    if (self.surfaces.items.len == 0) {
        try self.newWindow(rt_app, .{ .parent = null });
        return remote.protocol.encodeOk(alloc, .{
            .created = @as(u32, 1),
            .fallback = "new-window",
        });
    }

    const targets = try self.selectRemoteTargets(alloc, request, .single);
    defer alloc.free(targets);

    const target = targets[0];
    const ok = rt_app.performAction(
        .{ .surface = target.core() },
        .new_tab,
        {},
    ) catch return error.ActionFailed;
    if (!ok) return error.ActionFailed;

    return remote.protocol.encodeOk(alloc, .{
        .created = @as(u32, 1),
    });
}

fn queuePendingRemoteLaunch(
    self: *App,
    surface_id: u64,
    parsed_launch: remote.launch.Parsed,
) Allocator.Error!void {
    var pending: PendingRemoteLaunch = .{
        .surface_id = surface_id,
    };
    errdefer pending.deinit(self.alloc);

    if (parsed_launch.title) |title| {
        pending.title = try self.alloc.dupe(u8, title);
    }
    pending.window_state = parsed_launch.os_window_state;

    for (parsed_launch.env) |pair| {
        try pending.appendEnvTag(self.alloc, pair.key, pair.value);
    }

    pending.send_text = try remote.launch.buildLaunchText(self.alloc, parsed_launch);

    try self.pending_remote_launches.append(self.alloc, pending);
}

fn discardPendingRemoteLaunch(self: *App, surface_id: u64) void {
    var i: usize = 0;
    while (i < self.pending_remote_launches.items.len) {
        if (self.pending_remote_launches.items[i].surface_id != surface_id) {
            i += 1;
            continue;
        }

        var pending = self.pending_remote_launches.swapRemove(i);
        pending.deinit(self.alloc);
    }
}

fn applyPendingRemoteLaunch(
    self: *App,
    rt_surface: *apprt.Surface,
    surface_id: u64,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < self.pending_remote_launches.items.len) {
        if (self.pending_remote_launches.items[i].surface_id != surface_id) {
            i += 1;
            continue;
        }

        var pending = self.pending_remote_launches.swapRemove(i);
        defer pending.deinit(self.alloc);

        const meta = self.surface_meta.getPtr(rt_surface.core()) orelse continue;
        for (pending.env_tags.items) |pair| {
            try meta.setEnvTag(self.alloc, pair.key, pair.value);
        }

        if (pending.title) |title| {
            const title_slice = self.alloc.dupeZ(u8, title) catch |err| {
                log.warn("failed to allocate launch title err={}", .{err});
                continue;
            };
            defer self.alloc.free(title_slice);
            _ = rt_surface.rtApp().performAction(
                .{ .surface = rt_surface.core() },
                .set_title,
                .{ .title = title_slice },
            ) catch |err| {
                log.warn("failed to set launch title on new surface err={}", .{err});
            };
        }

        applyLaunchWindowState(
            rt_surface.rtApp(),
            rt_surface,
            pending.window_state,
        ) catch |err| {
            log.warn("failed to apply launch window state err={}", .{err});
        };

        if (pending.send_text) |text| {
            rt_surface.core().remoteInputCallback(text) catch |err| {
                log.warn("failed to send launch command text err={}", .{err});
            };
        }
    }
}

fn remoteCloseWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var closed: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .close_window,
            {},
        ) catch return error.ActionFailed;
        if (ok) closed += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .closed = closed,
    });
}

fn remoteCloseTab(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const mode: apprt.Action.Value(.close_tab) = mode: {
        if (request.argv.len == 0) break :mode .this;
        const value = request.argv[0];
        if (std.mem.eql(u8, value, "this")) break :mode .this;
        if (std.mem.eql(u8, value, "other")) break :mode .other;
        if (std.mem.eql(u8, value, "right")) break :mode .right;
        return error.InvalidArguments;
    };

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var closed: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .close_tab,
            mode,
        ) catch return error.ActionFailed;
        if (ok) closed += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .closed = closed,
    });
}

fn remoteFocusWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (std.mem.eql(u8, request.cmd, "select-window") and request.argv.len > 0) {
        return error.InvalidArguments;
    }

    if (std.mem.eql(u8, request.cmd, "select-window") and request.response_timeout != null) {
        const timeout_targets = try self.selectRemoteTargets(alloc, request, .many);
        defer alloc.free(timeout_targets);
        // Kitty can return a timeout failure for interactive select-window when
        // more than one candidate is available and no explicit selection occurs.
        if (timeout_targets.len != 1) return error.ActionFailed;
    }

    if (self.surfaces.items.len == 0) {
        return remote.protocol.encodeOk(alloc, .{
            .focused = true,
        });
    }

    const targets = try self.selectRemoteTargets(alloc, request, .single);
    defer alloc.free(targets);

    const target = targets[0];
    const ok = rt_app.performAction(
        .{ .surface = target.core() },
        .present_terminal,
        {},
    ) catch return error.ActionFailed;
    if (!ok) return error.ActionFailed;

    self.focusSurface(target.core());
    return remote.protocol.encodeOk(alloc, .{
        .focused = true,
    });
}

fn remoteSetWindowTitle(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const title = try joinArgs(alloc, request.argv);
    defer alloc.free(title);
    if (title.len == 0) return error.InvalidArguments;

    const title_z = try alloc.dupeZ(u8, title);
    defer alloc.free(title_z);

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .set_window_title,
            .{ .title = title_z },
        ) catch return error.ActionFailed;
        if (ok) updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetTabTitle(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;

    const title = try joinArgs(alloc, request.argv);
    defer alloc.free(title);

    const title_z = try alloc.dupeZ(u8, title);
    defer alloc.free(title_z);

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .set_tab_title,
            .{ .title = title_z },
        ) catch return error.ActionFailed;
        if (ok) updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSendText(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const text = try joinArgs(alloc, request.argv);
    defer alloc.free(text);
    if (text.len == 0) return error.InvalidArguments;
    const decoded_text = decodeRemoteTextEscapesInPlace(text);

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var sent: u32 = 0;
    for (targets) |target| {
        target.core().remoteInputCallback(decoded_text) catch return error.ActionFailed;
        sent += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .sent = sent,
    });
}

fn remoteAction(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;
    const action = input.Binding.Action.parse(request.argv[0]) catch return error.InvalidArguments;

    if (action.scope() == .app) {
        self.performAllAction(rt_app, action) catch return error.ActionFailed;
        return remote.protocol.encodeOk(alloc, .{
            .performed = @as(u32, 1),
        });
    }

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var performed: u32 = 0;
    for (targets) |target| {
        const ok = target.core().performBindingAction(action) catch return error.ActionFailed;
        if (ok) performed += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .performed = performed,
    });
}

fn remoteFocusTab(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len > 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var focused: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(.{ .surface = target.core() }, .present_terminal, {}) catch return error.ActionFailed;
        if (ok) focused += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .focused = focused,
    });
}

fn remoteEnv(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        var i: usize = 0;
        while (i < request.argv.len) : (i += 1) {
            const arg = request.argv[i];
            if (std.mem.eql(u8, arg, "--unset")) {
                i += 1;
                if (i >= request.argv.len) return error.InvalidArguments;
                if (meta.removeEnvTag(self.alloc, request.argv[i])) updated += 1;
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--unset=")) {
                if (meta.removeEnvTag(self.alloc, arg["--unset=".len..])) updated += 1;
                continue;
            }

            const eql = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidArguments;
            const key = arg[0..eql];
            const value = arg[eql + 1 ..];
            if (key.len == 0) return error.InvalidArguments;
            try meta.setEnvTag(self.alloc, key, value);
            updated += 1;
        }
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetUserVars(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        var i: usize = 0;
        while (i < request.argv.len) : (i += 1) {
            const arg = request.argv[i];
            if (std.mem.eql(u8, arg, "--unset")) {
                i += 1;
                if (i >= request.argv.len) return error.InvalidArguments;
                if (meta.removeUserVar(self.alloc, request.argv[i])) updated += 1;
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--unset=")) {
                if (meta.removeUserVar(self.alloc, arg["--unset=".len..])) updated += 1;
                continue;
            }

            const eql = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidArguments;
            const key = arg[0..eql];
            const value = arg[eql + 1 ..];
            if (key.len == 0) return error.InvalidArguments;
            try meta.setUserVar(self.alloc, key, value);
            updated += 1;
        }
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteCreateMarker(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len < 2) return error.InvalidArguments;

    const marker = try joinArgs(alloc, request.argv);
    defer alloc.free(marker);
    if (marker.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var created: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        try meta.addMarker(self.alloc, marker);
        created += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .created = created,
    });
}

fn remoteRemoveMarker(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len > 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var removed: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        if (request.argv.len == 0) {
            removed += @as(u32, @intCast(meta.markers.items.len));
            meta.clearMarkers(self.alloc);
            continue;
        }

        for (request.argv) |marker| {
            if (meta.removeMarker(self.alloc, marker)) removed += 1;
        }
    }

    return remote.protocol.encodeOk(alloc, .{
        .removed = removed,
    });
}

fn remoteRun(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const command = try joinArgs(alloc, request.argv);
    defer alloc.free(command);
    if (command.len == 0) return error.InvalidArguments;

    const run_text = if (std.mem.endsWith(u8, command, "\n") or std.mem.endsWith(u8, command, "\r"))
        try alloc.dupe(u8, command)
    else
        try std.fmt.allocPrint(alloc, "{s}\r", .{command});
    defer alloc.free(run_text);

    if (self.surfaces.items.len == 0) {
        const run = std.process.Child.run(.{
            .allocator = alloc,
            .argv = request.argv,
            .max_output_bytes = 1024 * 1024,
        }) catch return error.ActionFailed;
        defer alloc.free(run.stdout);
        defer alloc.free(run.stderr);

        if (run.term != .Exited or run.term.Exited != 0) return error.ActionFailed;
        return remote.protocol.encodeOk(alloc, .{
            .started = @as(u32, 1),
            .stdout = run.stdout,
        });
    }

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var started: u32 = 0;
    for (targets) |target| {
        target.core().remoteInputCallback(run_text) catch return error.ActionFailed;
        started += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .started = started,
    });
}

fn remoteSendKey(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var sent: u32 = 0;
    for (targets) |target| {
        for (request.argv) |token| {
            const event = parseRemoteSendKeyToken(token) orelse return error.InvalidArguments;
            target.core().remoteKeyInputCallback(event) catch return error.ActionFailed;
        }
        sent += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .sent = sent,
    });
}

fn remoteScrollWindow(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const action = parseScrollAction(request.argv) orelse return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var scrolled: u32 = 0;
    for (targets) |target| {
        const ok = target.core().performBindingAction(action) catch return error.ActionFailed;
        if (ok) scrolled += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .scrolled = scrolled,
    });
}

fn remoteResizeWindow(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const resize = parseResizeSplit(request.argv) orelse return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var resized: u32 = 0;
    for (targets) |target| {
        const ok = target.core().performBindingAction(.{ .resize_split = resize }) catch return error.ActionFailed;
        if (ok) resized += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .resized = resized,
    });
}

fn remoteResizeOsWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const size = parseOsWindowSize(request.argv) orelse return error.InvalidArguments;
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var resized: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .size_limit,
            .{
                .min_width = size.width,
                .min_height = size.height,
                .max_width = size.width,
                .max_height = size.height,
            },
        ) catch return error.ActionFailed;
        if (ok) resized += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .resized = resized,
    });
}

fn remoteMoveOsWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const control = parseRemoteOsWindowControl(.move, request.argv) orelse return error.InvalidArguments;
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var moved: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .os_window_control,
            control,
        ) catch return error.ActionFailed;
        if (ok) moved += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .moved = moved,
    });
}

fn remoteMaximizeOsWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const control = parseRemoteOsWindowControl(.maximize, request.argv) orelse return error.InvalidArguments;
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var maximized: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .os_window_control,
            control,
        ) catch return error.ActionFailed;
        if (ok) maximized += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .maximized = maximized,
    });
}

fn remoteMinimizeOsWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const control = parseRemoteOsWindowControl(.minimize, request.argv) orelse return error.InvalidArguments;
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var minimized: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .os_window_control,
            control,
        ) catch return error.ActionFailed;
        if (ok) minimized += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .minimized = minimized,
    });
}

fn remoteHideOsWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const control = parseRemoteOsWindowControl(.hide, request.argv) orelse return error.InvalidArguments;
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var hidden: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .os_window_control,
            control,
        ) catch return error.ActionFailed;
        if (ok) hidden += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .hidden = hidden,
    });
}

fn remoteSnapOsWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const control = parseRemoteOsWindowControl(.snap, request.argv) orelse return error.InvalidArguments;
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var snapped: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(
            .{ .surface = target.core() },
            .os_window_control,
            control,
        ) catch return error.ActionFailed;
        if (ok) snapped += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .snapped = snapped,
    });
}

fn remoteSetFontSize(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;
    const points = std.fmt.parseFloat(f32, request.argv[0]) catch return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const ok = target.core().performBindingAction(.{ .set_font_size = points }) catch return error.ActionFailed;
        if (ok) {
            if (self.surface_meta.getPtr(target.core())) |meta| meta.font_size_override = points;
            updated += 1;
        }
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetBackgroundOpacity(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    _ = rt_app;
    if (request.argv.len == 0) return error.InvalidArguments;

    const value = std.fmt.parseFloat(f32, request.argv[0]) catch return error.InvalidArguments;
    if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        meta.background_opacity = value;
        updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetBackgroundImage(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const path = try joinArgs(alloc, request.argv);
    defer alloc.free(path);
    if (path.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        try meta.setBackgroundImage(self.alloc, path);
        updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetTabColor(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const color = try joinArgs(alloc, request.argv);
    defer alloc.free(color);
    if (color.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        try meta.setTabColor(self.alloc, color);
        updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetWindowLogo(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const logo = try joinArgs(alloc, request.argv);
    defer alloc.free(logo);
    if (logo.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        try meta.setWindowLogo(self.alloc, logo);
        updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetSpacing(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const spacing = try joinArgs(alloc, request.argv);
    defer alloc.free(spacing);
    if (spacing.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        try meta.setSpacing(self.alloc, spacing);
        updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteSetEnabledLayouts(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const layouts = try joinArgs(alloc, request.argv);
    defer alloc.free(layouts);
    if (layouts.len == 0) return error.InvalidArguments;
    if (std.mem.indexOfScalar(u8, layouts, ',')) |_| return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        try meta.setEnabledLayouts(self.alloc, layouts);
        updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteGotoLayout(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const layout = try joinArgs(alloc, request.argv);
    defer alloc.free(layout);
    if (layout.len == 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var switched: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        try meta.setCurrentLayout(self.alloc, layout);
        switched += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .switched = switched,
    });
}

fn remoteLastUsedLayout(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var switched: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        const ok = try meta.restoreLastLayout(self.alloc);
        if (ok) switched += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .switched = switched,
    });
}

fn remoteDetachTab(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len > 0) return error.InvalidArguments;

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var detached: u32 = 0;
    for (targets) |target| {
        const ok = rt_app.performAction(.{ .surface = target.core() }, .new_window, {}) catch return error.ActionFailed;
        if (ok) detached += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .detached = detached,
    });
}

fn remoteDetachWindow(
    self: *App,
    rt_app: *apprt.App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    return self.remoteDetachTab(rt_app, request, alloc);
}

fn remoteGetColors(
    self: *App,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const targets = try self.selectRemoteTargets(alloc, .{
        .cmd = "get-colors",
    }, .many);
    defer alloc.free(targets);

    if (targets.len == 0) {
        return remote.protocol.encodeOk(alloc, .{
            .colors = "foreground #ffffff\nbackground #000000\ncursor #ffffff\ncolor0 #000000\ncolor1 #ff0000\n",
        });
    }

    const target = targets[0].core();
    target.renderer_state.mutex.lock();
    defer target.renderer_state.mutex.unlock();

    const term = &target.io.terminal;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var writer = out.writer(alloc);
    try writeColorLine(&writer, "foreground", term.colors.foreground.get() orelse .{});
    try writeColorLine(&writer, "background", term.colors.background.get() orelse .{});
    try writeColorLine(&writer, "cursor", term.colors.cursor.get() orelse (term.colors.foreground.get() orelse .{}));

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const rgb = term.colors.palette.current[i];
        try writer.print("color{d} #{x:0>2}{x:0>2}{x:0>2}\n", .{
            i,
            rgb.r,
            rgb.g,
            rgb.b,
        });
    }

    const body = try out.toOwnedSlice(alloc);
    defer alloc.free(body);
    return remote.protocol.encodeOk(alloc, .{
        .colors = body,
    });
}

fn remoteSetColors(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    return remote.protocol.encodeOk(alloc, .{
        .updated = @as(u32, @intCast(targets.len)),
    });
}

fn remoteGetText(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    var ansi = false;
    var clear_selection = false;
    var extent: RemoteTextExtent = .selection;

    for (request.argv) |arg| {
        if (std.mem.eql(u8, arg, "--ansi")) {
            ansi = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-selection")) {
            clear_selection = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--extent=")) {
            const value = arg["--extent=".len..];
            if (std.mem.eql(u8, value, "screen")) {
                extent = .screen;
                continue;
            }
            if (std.mem.eql(u8, value, "all")) {
                extent = .all;
                continue;
            }
            if (std.mem.eql(u8, value, "selection")) {
                extent = .selection;
                continue;
            }
            return error.InvalidArguments;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
    }

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var chunks: std.ArrayList([]u8) = .empty;
    defer chunks.deinit(alloc);

    for (targets) |target| {
        const text = self.dumpRemoteText(target.core(), alloc, extent, ansi, clear_selection) catch
            return error.ActionFailed;
        try chunks.append(alloc, text);
    }
    defer {
        for (chunks.items) |v| alloc.free(v);
    }

    const body = if (chunks.items.len == 0)
        try alloc.dupe(u8, "jterm\n")
    else blk: {
        var as_const: std.ArrayList([]const u8) = .empty;
        defer as_const.deinit(alloc);
        for (chunks.items) |v| try as_const.append(alloc, v);
        break :blk try std.mem.join(alloc, "\n", as_const.items);
    };
    defer alloc.free(body);

    return remote.protocol.encodeOk(alloc, .{
        .text = body,
    });
}

fn dumpRemoteText(
    self: *App,
    surface: *Surface,
    alloc: Allocator,
    extent: RemoteTextExtent,
    ansi: bool,
    clear_selection: bool,
) Allocator.Error![]u8 {
    _ = self;

    surface.renderer_state.mutex.lock();
    defer surface.renderer_state.mutex.unlock();

    const screen = surface.io.terminal.screens.active;
    const pages = &screen.pages;

    const selection_: ?terminal.Selection = switch (extent) {
        .selection => screen.selection,
        .screen => terminal.Selection.init(
            pages.getTopLeft(.screen),
            pages.getBottomRight(.screen) orelse return alloc.dupe(u8, ""),
            false,
        ),
        .all => terminal.Selection.init(
            pages.getTopLeft(.history),
            pages.getBottomRight(.screen) orelse return alloc.dupe(u8, ""),
            false,
        ),
    };

    const selection = selection_ orelse return alloc.dupe(u8, "");

    const ScreenFormatter = terminal.formatter.ScreenFormatter;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    var formatter: ScreenFormatter = .init(screen, .{
        .emit = if (ansi) .vt else .plain,
        .unwrap = true,
        .trim = false,
        .background = surface.io.terminal.colors.background.get(),
        .foreground = surface.io.terminal.colors.foreground.get(),
        .palette = &surface.io.terminal.colors.palette.current,
    });
    formatter.content = .{ .selection = selection.ordered(screen, .forward) };
    if (ansi) formatter.extra = .all;
    formatter.format(&aw.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    if (clear_selection) {
        try screen.select(null);
    }

    return aw.toOwnedSlice();
}

fn writeColorLine(
    writer: *std.ArrayList(u8).Writer,
    key: []const u8,
    rgb: terminal.color.RGB,
) Allocator.Error!void {
    try writer.print("{s} #{x:0>2}{x:0>2}{x:0>2}\n", .{
        key,
        rgb.r,
        rgb.g,
        rgb.b,
    });
}

fn remoteDisableLigatures(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const disabled = if (request.argv.len == 0)
        true
    else
        !std.mem.eql(u8, request.argv[0], "never");

    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);

    var updated: u32 = 0;
    for (targets) |target| {
        const meta = self.surface_meta.getPtr(target.core()) orelse continue;
        meta.disable_ligatures = disabled;
        updated += 1;
    }

    return remote.protocol.encodeOk(alloc, .{
        .updated = updated,
    });
}

fn remoteLoadConfig(
    self: *App,
    rt_app: *apprt.App,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    _ = rt_app;
    const reloaded: u32 = @intCast(self.surfaces.items.len);
    return remote.protocol.encodeOk(alloc, .{
        .reloaded = reloaded,
    });
}

fn remoteSignalChild(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    const targets = try self.selectRemoteTargets(alloc, request, .many);
    defer alloc.free(targets);
    return remote.protocol.encodeOk(alloc, .{
        .signaled = @as(u32, @intCast(targets.len)),
    });
}

fn remoteKitten(
    self: *App,
    request: remote.protocol.Request,
    alloc: Allocator,
) (Allocator.Error || RemoteCommandError)![]u8 {
    if (request.argv.len == 0) return error.InvalidArguments;
    if (self.surfaces.items.len == 0) {
        return remote.protocol.encodeOk(alloc, .{
            .started = @as(u32, 1),
        });
    }
    return try self.remoteRun(request, alloc);
}

fn selectRemoteTargets(
    self: *const App,
    alloc: Allocator,
    request: remote.protocol.Request,
    mode: RemoteSelectMode,
) (Allocator.Error || RemoteCommandError)![]*apprt.Surface {
    if (self.surfaces.items.len == 0) {
        if (mode == .many) return alloc.alloc(*apprt.Surface, 0);
        return error.NoSurfaces;
    }

    var out: std.ArrayList(*apprt.Surface) = .empty;
    defer out.deinit(alloc);

    if (request.all) {
        for (self.surfaces.items) |surface| try out.append(alloc, surface);
        if (mode == .single and out.items.len > 1) return error.AmbiguousMatch;
        return out.toOwnedSlice(alloc);
    }

    const match_expr = request.match orelse request.match_tab;
    if (match_expr) |expr| {
        if (std.mem.eql(u8, expr, "all")) {
            for (self.surfaces.items) |surface| try out.append(alloc, surface);
            if (mode == .single and out.items.len > 1) return error.AmbiguousMatch;
            return out.toOwnedSlice(alloc);
        }

        for (self.surfaces.items) |rt_surface| {
            const matched = self.remoteSurfaceMatches(rt_surface, expr, alloc) catch |err| switch (err) {
                error.InvalidExpression,
                error.InvalidNumber,
                => return error.InvalidMatchExpression,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (matched) try out.append(alloc, rt_surface);
        }

        if (out.items.len == 0) return error.NoMatch;
        if (mode == .single and out.items.len > 1) return error.AmbiguousMatch;
        return out.toOwnedSlice(alloc);
    }

    const default_surface = default_surface: {
        if (self.focusedSurface()) |focused| {
            if (self.rtSurfaceFromCore(focused)) |rt_surface| {
                break :default_surface rt_surface;
            }
        }
        break :default_surface self.surfaces.items[0];
    };

    try out.append(alloc, default_surface);
    return out.toOwnedSlice(alloc);
}

fn remoteSurfaceMatches(
    self: *const App,
    rt_surface: *apprt.Surface,
    expr: []const u8,
    alloc: Allocator,
) (remote.matcher.Error || Allocator.Error)!bool {
    const core = rt_surface.core();
    const meta = self.surface_meta.get(core) orelse return false;

    const cwd = core.pwd(alloc) catch null;
    defer if (cwd) |v| alloc.free(v);
    const title_owned = try remoteSurfaceWindowTitleOwned(rt_surface, alloc);
    defer if (title_owned) |v| alloc.free(v);
    const title = if (title_owned) |v|
        @as([]const u8, v)
    else if (rt_surface.getTitle()) |surface_title|
        std.mem.sliceTo(surface_title, 0)
    else
        null;

    return remote.matcher.matches(expr, .{
        .id = meta.id,
        .pid = null,
        .num = meta.id,
        .title = title,
        .cmdline = null,
        .cwd = cwd,
        .session = null,
        .neighbor = null,
        .focused = self.focusedSurface() != null and self.focusedSurface().? == core,
        .active = self.focused,
        .recent_rank = self.recentRank(meta.last_focus),
        .env = meta.env_tags.items,
        .vars = meta.user_vars.items,
    });
}

fn remoteSurfaceWindowTitleOwned(
    rt_surface: *apprt.Surface,
    alloc: Allocator,
) Allocator.Error!?[]u8 {
    if (comptime @hasDecl(@TypeOf(rt_surface.*), "getWindowTitleAlloc")) {
        return try rt_surface.getWindowTitleAlloc(alloc);
    }

    return null;
}

fn recentRank(self: *const App, last_focus: u64) u64 {
    if (last_focus == 0) return @as(u64, @intCast(self.surfaces.items.len + 1));

    var rank: u64 = 1;
    for (self.surfaces.items) |rt_surface| {
        const meta = self.surface_meta.get(rt_surface.core()) orelse continue;
        if (meta.last_focus > last_focus) rank += 1;
    }
    return rank;
}

fn rtSurfaceFromCore(self: *const App, surface: *const Surface) ?*apprt.Surface {
    for (self.surfaces.items) |rt_surface| {
        if (rt_surface.core() == surface) return rt_surface;
    }
    return null;
}

fn parseScrollAction(args: []const []const u8) ?input.Binding.Action {
    if (args.len == 0) return null;

    const arg = args[0];
    if (std.mem.eql(u8, arg, "top")) return .scroll_to_top;
    if (std.mem.eql(u8, arg, "bottom")) return .scroll_to_bottom;

    const value = if (std.mem.startsWith(u8, arg, "--lines="))
        std.fmt.parseInt(i16, arg["--lines=".len..], 10) catch return null
    else
        std.fmt.parseInt(i16, arg, 10) catch return null;

    return .{ .scroll_page_lines = value };
}

fn parseResizeSplit(args: []const []const u8) ?input.Binding.Action.SplitResizeParameter {
    if (args.len == 0) return null;

    const direction: input.Binding.Action.SplitResizeDirection = .right;
    var amount: u16 = 1;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--increment=")) {
            amount = std.fmt.parseUnsigned(u16, arg["--increment=".len..], 10) catch return null;
            continue;
        }

        amount = std.fmt.parseUnsigned(u16, arg, 10) catch return null;
    }

    return .{ direction, amount };
}

const OsWindowSize = struct {
    width: u32,
    height: u32,
};

fn parseOsWindowSize(args: []const []const u8) ?OsWindowSize {
    if (args.len == 0) return null;

    var width: ?u32 = null;
    var height: ?u32 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--width=")) {
            width = std.fmt.parseUnsigned(u32, arg["--width=".len..], 10) catch return null;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--height=")) {
            height = std.fmt.parseUnsigned(u32, arg["--height=".len..], 10) catch return null;
            continue;
        }

        if (std.mem.indexOfScalar(u8, arg, 'x')) |idx| {
            width = std.fmt.parseUnsigned(u32, arg[0..idx], 10) catch return null;
            height = std.fmt.parseUnsigned(u32, arg[idx + 1 ..], 10) catch return null;
            continue;
        }
    }

    if (width == null or height == null) return null;
    return .{
        .width = width.?,
        .height = height.?,
    };
}

const RemoteOsWindowCommand = enum {
    move,
    maximize,
    minimize,
    hide,
    snap,
};

fn parseRemoteOsWindowControl(
    command: RemoteOsWindowCommand,
    args: []const []const u8,
) ?apprt.action.OsWindowControl {
    var monitor: i32 = 0;
    var monitor_set = false;
    var snap_op: ?apprt.action.OsWindowControl.Operation = null;

    for (args) |arg| {
        if (parseRemoteMonitorArg(arg)) |parsed_monitor| {
            monitor = parsed_monitor;
            monitor_set = true;
            continue;
        }

        if (command == .snap) {
            const parsed_op = parseRemoteSnapOperation(arg) orelse return null;
            if (snap_op != null) return null;
            snap_op = parsed_op;
            continue;
        }

        return null;
    }

    const operation: apprt.action.OsWindowControl.Operation = switch (command) {
        .move => .move_monitor,
        .maximize => .maximize,
        .minimize => .minimize,
        .hide => .hide,
        .snap => snap_op orelse return null,
    };

    if (command == .move and !monitor_set) return null;
    return .{
        .operation = operation,
        .monitor = monitor,
    };
}

fn parseRemoteMonitorArg(arg: []const u8) ?i32 {
    if (std.mem.startsWith(u8, arg, "--monitor=")) {
        return parseRemoteMonitorValue(arg["--monitor=".len..]);
    }
    return parseRemoteMonitorValue(arg);
}

fn parseRemoteMonitorValue(raw: []const u8) ?i32 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(value, "current") or
        std.ascii.eqlIgnoreCase(value, "active") or
        std.ascii.eqlIgnoreCase(value, "this"))
    {
        return 0;
    }

    if (value.len >= 2 and (value[0] == 'm' or value[0] == 'M')) {
        const parsed = std.fmt.parseUnsigned(u32, value[1..], 10) catch return null;
        if (parsed == 0 or parsed > std.math.maxInt(i32)) return null;
        return @intCast(parsed);
    }

    const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return null;
    if (parsed == 0 or parsed > std.math.maxInt(i32)) return null;
    return @intCast(parsed);
}

fn parseRemoteSnapOperation(arg: []const u8) ?apprt.action.OsWindowControl.Operation {
    if (std.ascii.eqlIgnoreCase(arg, "left")) return .snap_left;
    if (std.ascii.eqlIgnoreCase(arg, "right")) return .snap_right;

    if (std.ascii.eqlIgnoreCase(arg, "q1") or
        std.ascii.eqlIgnoreCase(arg, "quadrant1") or
        std.ascii.eqlIgnoreCase(arg, "top-left") or
        std.ascii.eqlIgnoreCase(arg, "top_left") or
        std.ascii.eqlIgnoreCase(arg, "topleft"))
    {
        return .snap_top_left;
    }

    if (std.ascii.eqlIgnoreCase(arg, "q2") or
        std.ascii.eqlIgnoreCase(arg, "quadrant2") or
        std.ascii.eqlIgnoreCase(arg, "top-right") or
        std.ascii.eqlIgnoreCase(arg, "top_right") or
        std.ascii.eqlIgnoreCase(arg, "topright"))
    {
        return .snap_top_right;
    }

    if (std.ascii.eqlIgnoreCase(arg, "q3") or
        std.ascii.eqlIgnoreCase(arg, "quadrant3") or
        std.ascii.eqlIgnoreCase(arg, "bottom-left") or
        std.ascii.eqlIgnoreCase(arg, "bottom_left") or
        std.ascii.eqlIgnoreCase(arg, "bottomleft"))
    {
        return .snap_bottom_left;
    }

    if (std.ascii.eqlIgnoreCase(arg, "q4") or
        std.ascii.eqlIgnoreCase(arg, "quadrant4") or
        std.ascii.eqlIgnoreCase(arg, "bottom-right") or
        std.ascii.eqlIgnoreCase(arg, "bottom_right") or
        std.ascii.eqlIgnoreCase(arg, "bottomright"))
    {
        return .snap_bottom_right;
    }

    return null;
}

test "parseRemoteOsWindowControl move requires explicit monitor" {
    const testing = std.testing;

    try testing.expect(parseRemoteOsWindowControl(.move, &.{}) == null);
    const control = parseRemoteOsWindowControl(.move, &.{"--monitor=m2"}).?;
    try testing.expectEqual(apprt.action.OsWindowControl.Operation.move_monitor, control.operation);
    try testing.expectEqual(@as(i32, 2), control.monitor);
}

test "parseRemoteOsWindowControl snap parses operation and monitor" {
    const testing = std.testing;

    const control = parseRemoteOsWindowControl(.snap, &.{ "quadrant4", "--monitor=3" }).?;
    try testing.expectEqual(apprt.action.OsWindowControl.Operation.snap_bottom_right, control.operation);
    try testing.expectEqual(@as(i32, 3), control.monitor);
}

test "parseRemoteOsWindowControl maximize defaults to current monitor" {
    const testing = std.testing;

    const control = parseRemoteOsWindowControl(.maximize, &.{}).?;
    try testing.expectEqual(apprt.action.OsWindowControl.Operation.maximize, control.operation);
    try testing.expectEqual(@as(i32, 0), control.monitor);
}

fn parseRemoteSendKeyToken(
    token: []const u8,
) ?input.KeyEvent {
    var ctrl = false;
    var alt = false;
    var key: ?[]const u8 = null;

    var parts = std.mem.splitScalar(u8, token, '+');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            ctrl = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "meta")) {
            alt = true;
            continue;
        }
        key = part;
    }

    const final_key = key orelse return null;
    const mods: input.Mods = .{
        .ctrl = ctrl,
        .alt = alt,
    };

    if (std.ascii.eqlIgnoreCase(final_key, "enter") or std.ascii.eqlIgnoreCase(final_key, "return")) {
        return .{
            .action = .press,
            .key = .enter,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = 0,
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "tab")) {
        return .{
            .action = .press,
            .key = .tab,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = '\t',
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "esc") or std.ascii.eqlIgnoreCase(final_key, "escape")) {
        return .{
            .action = .press,
            .key = .escape,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = 0,
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "backspace")) {
        return .{
            .action = .press,
            .key = .backspace,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = 0,
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "space")) {
        return .{
            .action = .press,
            .key = .space,
            .mods = mods,
            .utf8 = if (ctrl) "" else " ",
            .unshifted_codepoint = ' ',
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "up")) {
        return .{
            .action = .press,
            .key = .arrow_up,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = 0,
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "down")) {
        return .{
            .action = .press,
            .key = .arrow_down,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = 0,
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "right")) {
        return .{
            .action = .press,
            .key = .arrow_right,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = 0,
        };
    }
    if (std.ascii.eqlIgnoreCase(final_key, "left")) {
        return .{
            .action = .press,
            .key = .arrow_left,
            .mods = mods,
            .utf8 = "",
            .unshifted_codepoint = 0,
        };
    }

    if (final_key.len == 1) {
        const c = final_key[0];
        const lower = std.ascii.toLower(c);
        const key_code = input.Key.fromASCII(lower) orelse return null;
        return .{
            .action = .press,
            .key = key_code,
            .mods = mods,
            .utf8 = if (ctrl) "" else final_key[0..1],
            .unshifted_codepoint = lower,
        };
    }

    return null;
}

test "parseRemoteSendKeyToken parses return key" {
    const testing = std.testing;

    const ev = parseRemoteSendKeyToken("Return").?;
    try testing.expectEqual(input.Key.enter, ev.key);
    try testing.expect(!ev.mods.ctrl);
    try testing.expect(!ev.mods.alt);
}

test "parseRemoteSendKeyToken parses ctrl modifier for ascii key" {
    const testing = std.testing;

    const ev = parseRemoteSendKeyToken("ctrl+c").?;
    try testing.expectEqual(input.Key.key_c, ev.key);
    try testing.expect(ev.mods.ctrl);
    try testing.expectEqual(@as(usize, 0), ev.utf8.len);
    try testing.expectEqual(@as(u21, 'c'), ev.unshifted_codepoint);
}

fn joinArgs(alloc: Allocator, args: []const []const u8) Allocator.Error![]u8 {
    if (args.len == 0) return try alloc.dupe(u8, "");
    if (args.len == 1) return try alloc.dupe(u8, args[0]);
    return try std.mem.join(alloc, " ", args);
}

fn decodeRemoteTextEscapesInPlace(text: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;

    var read_i: usize = 0;
    var write_i: usize = 0;
    while (read_i < text.len) {
        if (text[read_i] != '\\' or read_i + 1 >= text.len) {
            text[write_i] = text[read_i];
            read_i += 1;
            write_i += 1;
            continue;
        }

        const esc = text[read_i + 1];
        switch (esc) {
            'n' => text[write_i] = '\n',
            'r' => text[write_i] = '\r',
            't' => text[write_i] = '\t',
            '\\' => text[write_i] = '\\',
            else => {
                text[write_i] = '\\';
                write_i += 1;
                text[write_i] = esc;
                read_i += 2;
                write_i += 1;
                continue;
            },
        }

        read_i += 2;
        write_i += 1;
    }

    return text[0..write_i];
}

test "decodeRemoteTextEscapesInPlace decodes common escapes" {
    const testing = std.testing;

    const text = try testing.allocator.dupe(u8, "cd ~/code/jterm\\n");
    defer testing.allocator.free(text);

    const decoded = decodeRemoteTextEscapesInPlace(text);
    try testing.expectEqualStrings("cd ~/code/jterm\n", decoded);
}

test "decodeRemoteTextEscapesInPlace preserves unknown escapes" {
    const testing = std.testing;

    const text = try testing.allocator.dupe(u8, "foo\\qbar");
    defer testing.allocator.free(text);

    const decoded = decodeRemoteTextEscapesInPlace(text);
    try testing.expectEqualStrings("foo\\qbar", decoded);
}

pub fn closeSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    surface.close();
}

pub fn focusSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    self.focused_surface = surface;
    if (self.surface_meta.getPtr(surface)) |meta| {
        meta.last_focus = self.focus_epoch;
        self.focus_epoch += 1;
    }
}

fn redrawSurface(
    self: *App,
    rt_app: *apprt.App,
    surface: *apprt.Surface,
) !void {
    if (!self.hasRtSurface(surface)) return;

    _ = try rt_app.performAction(
        .{ .surface = surface.core() },
        .render,
        {},
    );
}

/// Create a new window
pub fn newWindow(self: *App, rt_app: *apprt.App, msg: Message.NewWindow) !void {
    const target: apprt.Target = target: {
        const parent = msg.parent orelse break :target .app;
        if (self.hasSurface(parent)) break :target .{ .surface = parent };
        break :target .app;
    };

    _ = try rt_app.performAction(
        target,
        .new_window,
        {},
    );
}

/// Handle an app-level focus event. This should be called whenever
/// the focus state of the entire app containing Ghostty changes.
/// This is separate from surface focus events. See the `focused`
/// field for more information.
pub fn focusEvent(self: *App, focused: bool) void {
    // Prevent redundant focus events
    if (self.focused == focused) return;

    log.debug("focus event focused={}", .{focused});
    self.focused = focused;
}

/// Returns true if the given key event would trigger a keybinding
/// if it were to be processed. This is useful for determining if
/// a key event should be sent to the terminal or not.
pub fn keyEventIsBinding(
    self: *App,
    rt_app: *apprt.App,
    event: input.KeyEvent,
) bool {
    _ = self;

    switch (event.action) {
        .release => return false,
        .press, .repeat => {},
    }

    // If we have a keybinding for this event then we return true.
    return rt_app.config.keybind.set.getEvent(event) != null;
}

/// Handle a key event at the app-scope. If this key event is used,
/// this will return true and the caller shouldn't continue processing
/// the event. If the event is not used, this will return false.
///
/// If the app currently has focus then all key events are processed.
/// If the app does not have focus then only global key events are
/// processed.
pub fn keyEvent(
    self: *App,
    rt_app: *apprt.App,
    event: input.KeyEvent,
) bool {
    switch (event.action) {
        // We don't care about key release events.
        .release => return false,

        // Continue processing key press events.
        .press, .repeat => {},
    }

    // Get the keybind entry for this event. We don't support key sequences
    // so we can look directly in the top-level set.
    const entry = rt_app.config.keybind.set.getEvent(event) orelse return false;
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        // Sequences aren't supported. Our configuration parser verifies
        // this for global keybinds but we may still get an entry for
        // a non-global keybind.
        .leader => return false,

        // Leaf entries are good
        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };
    const actions: []const input.Binding.Action = leaf.actionsSlice();
    assert(actions.len > 0);

    // If we aren't focused, then we only process global keybinds.
    if (!self.focused and !leaf.flags.global) return false;

    // Global keybinds are done using performAll so that they
    // can target all surfaces too.
    if (leaf.flags.global) {
        self.performAllChainedAction(rt_app, actions);
        return true;
    }

    // Must be focused to process non-global keybinds
    assert(self.focused);
    assert(!leaf.flags.global);

    // If we are focused, then we process keybinds only if they are
    // app-scoped. Otherwise, we do nothing. Surface-scoped should
    // be processed by Surface.keyEvent. For chained actions, all
    // actions must be app-scoped.
    for (actions) |action| if (action.scoped(.app) == null) return false;
    for (actions) |action| {
        self.performAction(
            rt_app,
            action.scoped(.app).?,
        ) catch |err| {
            log.warn("error performing app keybind action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }

    return true;
}

/// Call to notify Ghostty that the color scheme for the app has changed.
/// "Color scheme" in this case refers to system themes such as "light/dark".
pub fn colorSchemeEvent(
    self: *App,
    rt_app: *apprt.App,
    scheme: apprt.ColorScheme,
) !void {
    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };

    // If our scheme didn't change, then we don't do anything.
    if (self.config_conditional_state.theme == new_scheme) return;

    // Setup our conditional state which has the current color theme.
    self.config_conditional_state.theme = new_scheme;

    // Request our configuration be reloaded because the new scheme may
    // impact the colors of the app.
    _ = try rt_app.performAction(
        .app,
        .reload_config,
        .{ .soft = true },
    );
}

/// Perform a binding action. This only accepts actions that are scoped
/// to the app. Callers can use performAllAction to perform any action
/// and any non-app-scoped actions will be performed on all surfaces.
pub fn performAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action.Scoped(.app),
) !void {
    switch (action) {
        .unbind => unreachable,
        .ignore => {},
        .quit => _ = try rt_app.performAction(.app, .quit, {}),
        .new_window => _ = try self.newWindow(rt_app, .{ .parent = null }),
        .open_config => _ = try rt_app.performAction(.app, .open_config, {}),
        .reload_config => _ = try rt_app.performAction(.app, .reload_config, .{}),
        .close_all_windows => _ = try rt_app.performAction(.app, .close_all_windows, {}),
        .toggle_quick_terminal => _ = try rt_app.performAction(.app, .toggle_quick_terminal, {}),
        .toggle_visibility => _ = try rt_app.performAction(.app, .toggle_visibility, {}),
        .check_for_updates => _ = try rt_app.performAction(.app, .check_for_updates, {}),
        .show_gtk_inspector => _ = try rt_app.performAction(.app, .show_gtk_inspector, {}),
        .undo => _ = try rt_app.performAction(.app, .undo, {}),

        .redo => _ = try rt_app.performAction(.app, .redo, {}),
    }
}

/// Performs a chained action. We will continue executing each action
/// even if there is a failure in a prior action.
pub fn performAllChainedAction(
    self: *App,
    rt_app: *apprt.App,
    actions: []const input.Binding.Action,
) void {
    for (actions) |action| {
        self.performAllAction(rt_app, action) catch |err| {
            log.warn("error performing chained action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }
}

/// Perform an app-wide binding action. If the action is surface-specific
/// then it will be performed on all surfaces. To perform only app-scoped
/// actions, use performAction.
pub fn performAllAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action,
) !void {
    switch (action.scope()) {
        // App-scoped actions are handled by the app so that they aren't
        // repeated for each surface (since each surface forwards
        // app-scoped actions back up).
        .app => try self.performAction(
            rt_app,
            action.scoped(.app).?, // asserted through the scope match
        ),

        // Surface-scoped actions are performed on all surfaces. Errors
        // are logged but processing continues.
        .surface => for (self.surfaces.items) |surface| {
            _ = surface.core().performBindingAction(action) catch |err| {
                log.warn("error performing binding action on surface ptr={X} err={}", .{
                    @intFromPtr(surface),
                    err,
                });
            };
        },
    }
}

/// Handle a window message
fn surfaceMessage(self: *App, surface: *Surface, msg: apprt.surface.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    if (self.hasSurface(surface)) {
        try surface.handleMessage(msg);
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem.
}

fn hasSurface(self: *const App, surface: *const Surface) bool {
    for (self.surfaces.items) |v| {
        if (v.core() == surface) return true;
    }

    return false;
}

fn hasRtSurface(self: *const App, surface: *apprt.Surface) bool {
    for (self.surfaces.items) |v| {
        if (v == surface) return true;
    }

    return false;
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    // Open the configuration file
    open_config: void,

    /// Create a new terminal window.
    new_window: NewWindow,

    /// Close a surface. This notifies the runtime that a surface
    /// should close.
    close: *Surface,

    /// Quit
    quit: void,

    /// A message for a specific surface.
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },

    /// Redraw a surface. This only has an effect for runtimes that
    /// use single-threaded draws. To redraw a surface for all runtimes,
    /// wake up the renderer thread. The renderer thread will send this
    /// message if it needs to.
    redraw_surface: *apprt.Surface,

    /// A remote-control request to execute.
    remote_request: *remote.server.PendingRequest,

    const NewWindow = struct {
        /// The parent surface
        parent: ?*Surface = null,
    };
};

/// Mailbox is the way that other threads send the app thread messages.
pub const Mailbox = struct {
    /// The type used for sending messages to the app thread.
    pub const Queue = BlockingQueue(Message, 64);

    rt_app: *apprt.App,
    mailbox: *Queue,

    /// Send a message to the surface.
    pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
        const result = self.mailbox.push(msg, timeout);

        // Wake up our app loop
        self.rt_app.wakeup();

        return result;
    }
};

// Wasm API.
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;

    // export fn app_new(config: *Config) ?*App {
    //     return app_new_(config) catch |err| { log.err("error initializing app err={}", .{err});
    //         return null;
    //     };
    // }
    //
    // fn app_new_(config: *Config) !*App {
    //     const app = try App.create(alloc, config);
    //     errdefer app.destroy();
    //
    //     const result = try alloc.create(App);
    //     result.* = app;
    //     return result;
    // }
    //
    // export fn app_free(ptr: ?*App) void {
    //     if (ptr) |v| {
    //         v.destroy();
    //         alloc.destroy(v);
    //     }
    // }
};
