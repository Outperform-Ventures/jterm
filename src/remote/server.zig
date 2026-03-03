const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const matcher = @import("matcher.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

pub const RequestError = error{
    RequestTooLarge,
    EmptyRequest,
};

/// Request passed from the server thread into the app thread.
pub const PendingRequest = struct {
    request_json: []const u8,
    response_json: ?[]u8 = null,
    completed: bool = false,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn complete(self: *PendingRequest, response: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.response_json = response;
        self.completed = true;
        self.cond.signal();
    }

    pub fn wait(self: *PendingRequest) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.completed) self.cond.wait(&self.mutex);
    }
};

pub const Submitter = struct {
    userdata: *anyopaque,
    submitFn: *const fn (userdata: *anyopaque, req: *PendingRequest) bool,

    pub fn submit(self: Submitter, req: *PendingRequest) bool {
        return self.submitFn(self.userdata, req);
    }
};

pub const Server = struct {
    alloc: Allocator,
    submitter: Submitter,
    socket_path: []u8,
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(
        alloc: Allocator,
        submitter: Submitter,
        socket_path: []const u8,
    ) Allocator.Error!Server {
        return .{
            .alloc = alloc,
            .submitter = submitter,
            .socket_path = try alloc.dupe(u8, socket_path),
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.alloc.free(self.socket_path);
        self.* = undefined;
    }

    pub fn start(self: *Server) !void {
        if (self.thread != null) return;

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(
            .{},
            threadMain,
            .{self},
        );
        self.thread.?.setName("remote-server") catch {};
    }

    pub fn stop(self: *Server) void {
        const thread = self.thread orelse return;
        self.running.store(false, .release);
        wakeListener(self.socket_path);
        thread.join();
        self.thread = null;
    }

    fn wakeListener(path: []const u8) void {
        if (!std.net.has_unix_sockets) return;
        const stream = std.net.connectUnixSocket(path) catch return;
        defer stream.close();
    }

    fn threadMain(self: *Server) void {
        self.threadMain_() catch |err| {
            std.log.err("remote server thread failed err={}", .{err});
        };
    }

    fn threadMain_(self: *Server) !void {
        if (!std.net.has_unix_sockets) return;

        std.fs.deleteFileAbsolute(self.socket_path) catch {};

        var addr = try std.net.Address.initUnix(self.socket_path);
        var server = try addr.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();
        defer std.fs.deleteFileAbsolute(self.socket_path) catch {};

        // Restrict local socket permissions to owner-only where possible.
        std.posix.fchmodat(std.fs.cwd().fd, self.socket_path, 0o600, 0) catch {};

        while (self.running.load(.acquire)) {
            var conn = server.accept() catch |err| {
                if (!self.running.load(.acquire)) break;
                std.log.warn("remote server accept error err={}", .{err});
                continue;
            };
            defer conn.stream.close();

            self.handleConnection(conn.stream) catch |err| {
                if (err == error.EmptyRequest) continue;
                const encoded = protocol.encodeError(self.alloc, "request handling failed") catch continue;
                defer self.alloc.free(encoded);
                _ = conn.stream.writeAll(encoded) catch {};
                _ = conn.stream.writeAll("\n") catch {};
                std.log.warn("remote server connection error err={}", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, stream: std.net.Stream) !void {
        const request = try readRequest(self.alloc, stream);
        defer self.alloc.free(request);
        const use_dcs = protocol.isDcsFrame(request);

        const no_response = no_response: {
            var parsed = protocol.parseWireRequest(self.alloc, request) catch break :no_response false;
            defer parsed.deinit();
            break :no_response switch (parsed) {
                .plain => |plain| plain.value.no_response,
                .encrypted => false,
            };
        };

        var pending: PendingRequest = .{
            .request_json = request,
        };
        if (!self.submitter.submit(&pending)) {
            const encoded = try protocol.encodeError(self.alloc, "server is unavailable");
            defer self.alloc.free(encoded);
            try writeResponse(self.alloc, stream, encoded, use_dcs);
            return;
        }

        pending.wait();
        if (no_response) {
            if (pending.response_json) |response| {
                defer self.alloc.free(response);
                if (responseIsError(response)) {
                    try writeResponse(self.alloc, stream, response, use_dcs);
                }
            }
            return;
        }

        const response = pending.response_json orelse {
            const encoded = try protocol.encodeError(self.alloc, "no response");
            defer self.alloc.free(encoded);
            try writeResponse(self.alloc, stream, encoded, use_dcs);
            return;
        };
        defer self.alloc.free(response);

        try writeResponse(self.alloc, stream, response, use_dcs);
    }
};

fn responseIsError(response_json: []const u8) bool {
    return std.mem.indexOf(u8, response_json, "\"ok\":false") != null;
}

fn readRequest(alloc: Allocator, stream: std.net.Stream) (Allocator.Error || RequestError || std.net.Stream.ReadError)![]u8 {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;

        const chunk = buf[0..n];
        try data.appendSlice(alloc, chunk);
        if (std.mem.startsWith(u8, data.items, protocol.dcs_prefix)) {
            if (std.mem.indexOf(u8, data.items, protocol.dcs_suffix) != null) break;
        } else if (std.mem.indexOfScalar(u8, data.items, '\n') != null) {
            const idx = std.mem.indexOfScalar(u8, data.items, '\n').?;
            data.items.len = idx;
            break;
        }

        if (data.items.len > protocol.max_message_size) {
            return error.RequestTooLarge;
        }
    }

    if (data.items.len == 0) return error.EmptyRequest;
    return data.toOwnedSlice(alloc);
}

fn writeResponse(
    alloc: Allocator,
    stream: std.net.Stream,
    response_json: []const u8,
    use_dcs: bool,
) !void {
    if (use_dcs) {
        const framed = try protocol.wrapFrame(alloc, response_json);
        defer alloc.free(framed);
        try stream.writeAll(framed);
        return;
    }

    try stream.writeAll(response_json);
    try stream.writeAll("\n");
}

test "server roundtrip handles a request" {
    const testing = std.testing;
    if (!std.net.has_unix_sockets) return;

    const SubmitState = struct {
        fn submit(_: *anyopaque, req: *PendingRequest) bool {
            const alloc = std.heap.page_allocator;
            const response = protocol.encodeOk(alloc, .{ .status = "ok" }) catch return false;
            req.complete(response);
            return true;
        }
    };

    const path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/jterm-test-{d}.sock",
        .{std.time.milliTimestamp()},
    );
    defer testing.allocator.free(path);

    var server = try Server.init(
        std.heap.page_allocator,
        .{
            .userdata = undefined,
            .submitFn = SubmitState.submit,
        },
        path,
    );
    defer server.deinit();
    try server.start();

    // Let the listener bind.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const target = try std.fmt.allocPrint(
        testing.allocator,
        "unix:{s}",
        .{path},
    );
    defer testing.allocator.free(target);

    const request = try protocol.encodeRequest(testing.allocator, .{
        .cmd = "ls",
    });
    defer testing.allocator.free(request);

    const response = try transport.request(testing.allocator, target, request);
    defer testing.allocator.free(response);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expectEqualStrings(
        "ok",
        parsed.value.object.get("data").?.object.get("status").?.string,
    );
}

test "server command matrix roundtrip" {
    const testing = std.testing;
    if (!std.net.has_unix_sockets) return;

    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa_alloc = gpa_state.allocator();

    const Mock = struct {
        const Window = struct {
            id: u64,
            title: []u8,
            last_focus: u64 = 0,
        };

        const SelectMode = enum {
            single,
            many,
        };

        const DispatchError = error{
            UnsupportedCommand,
            NoSurfaces,
            NoMatch,
            AmbiguousMatch,
            InvalidArguments,
            InvalidMatchExpression,
        };

        alloc: Allocator,
        windows: std.ArrayList(Window) = .empty,
        next_id: u64 = 1,
        focus_epoch: u64 = 1,
        focused: ?u64 = null,
        sent_count: u32 = 0,

        fn deinit(self: *@This()) void {
            for (self.windows.items) |window| self.alloc.free(window.title);
            self.windows.deinit(self.alloc);
        }

        fn submit(ctx: *anyopaque, req: *PendingRequest) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));

            var parsed = protocol.parseRequest(self.alloc, req.request_json) catch {
                const encoded = protocol.encodeError(self.alloc, "invalid request payload") catch return false;
                req.complete(encoded);
                return true;
            };
            defer parsed.deinit();

            const response = self.dispatch(parsed.value) catch |err| response: {
                const message = switch (err) {
                    error.UnsupportedCommand => "unsupported remote-control command",
                    error.NoSurfaces => "no surfaces are available",
                    error.NoMatch => "no target matched the request",
                    error.AmbiguousMatch => "match expression resolved to multiple targets",
                    error.InvalidArguments => "invalid command arguments",
                    error.InvalidMatchExpression => "invalid match expression",
                    else => "remote-control command failed",
                };
                break :response protocol.encodeError(self.alloc, message) catch return false;
            };
            req.complete(response);
            return true;
        }

        fn dispatch(
            self: *@This(),
            request: protocol.Request,
        ) (Allocator.Error || DispatchError)![]u8 {
            if (std.mem.eql(u8, request.cmd, "ls")) {
                const Entry = struct {
                    id: u64,
                    focused: bool,
                    recent: u64,
                    title: []const u8,
                };

                var entries: std.ArrayList(Entry) = .empty;
                defer entries.deinit(self.alloc);

                for (self.windows.items) |window| {
                    try entries.append(self.alloc, .{
                        .id = window.id,
                        .focused = self.focused != null and self.focused.? == window.id,
                        .recent = self.recentRank(window.last_focus),
                        .title = window.title,
                    });
                }

                return protocol.encodeOk(self.alloc, .{
                    .surfaces = entries.items,
                });
            }

            if (std.mem.eql(u8, request.cmd, "new-window") or
                std.mem.eql(u8, request.cmd, "new-tab") or
                std.mem.eql(u8, request.cmd, "launch"))
            {
                const id = self.next_id;
                self.next_id += 1;

                try self.windows.append(self.alloc, .{
                    .id = id,
                    .title = try self.alloc.dupe(u8, ""),
                });
                self.focusWindow(id);

                return protocol.encodeOk(self.alloc, .{
                    .created = @as(u32, 1),
                    .id = id,
                });
            }

            if (std.mem.eql(u8, request.cmd, "close-window")) {
                const targets = try self.selectTargets(request, .many);
                defer self.alloc.free(targets);

                var closed: u32 = 0;
                for (targets) |id| {
                    if (self.removeWindowById(id)) closed += 1;
                }

                return protocol.encodeOk(self.alloc, .{
                    .closed = closed,
                });
            }

            if (std.mem.eql(u8, request.cmd, "close-tab")) {
                if (request.argv.len > 1) return error.InvalidArguments;
                if (request.argv.len == 1) {
                    const value = request.argv[0];
                    if (!std.mem.eql(u8, value, "this") and
                        !std.mem.eql(u8, value, "other") and
                        !std.mem.eql(u8, value, "right"))
                    {
                        return error.InvalidArguments;
                    }
                }

                const targets = try self.selectTargets(request, .many);
                defer self.alloc.free(targets);

                var closed: u32 = 0;
                for (targets) |id| {
                    if (self.removeWindowById(id)) closed += 1;
                }

                return protocol.encodeOk(self.alloc, .{
                    .closed = closed,
                });
            }

            if (std.mem.eql(u8, request.cmd, "focus-window") or
                std.mem.eql(u8, request.cmd, "select-window"))
            {
                const targets = try self.selectTargets(request, .single);
                defer self.alloc.free(targets);
                self.focusWindow(targets[0]);

                return protocol.encodeOk(self.alloc, .{
                    .focused = true,
                });
            }

            if (std.mem.eql(u8, request.cmd, "set-window-title") or
                std.mem.eql(u8, request.cmd, "set-tab-title"))
            {
                const title = try joinArgs(self.alloc, request.argv);
                defer self.alloc.free(title);
                if (title.len == 0) return error.InvalidArguments;

                const targets = try self.selectTargets(request, .many);
                defer self.alloc.free(targets);

                var updated: u32 = 0;
                for (targets) |id| {
                    const idx = self.windowIndexById(id) orelse continue;
                    self.alloc.free(self.windows.items[idx].title);
                    self.windows.items[idx].title = try self.alloc.dupe(u8, title);
                    updated += 1;
                }

                return protocol.encodeOk(self.alloc, .{
                    .updated = updated,
                });
            }

            if (std.mem.eql(u8, request.cmd, "send-text")) {
                const text = try joinArgs(self.alloc, request.argv);
                defer self.alloc.free(text);
                if (text.len == 0) return error.InvalidArguments;

                const targets = try self.selectTargets(request, .many);
                defer self.alloc.free(targets);

                self.sent_count += @as(u32, @intCast(targets.len));
                return protocol.encodeOk(self.alloc, .{
                    .sent = @as(u32, @intCast(targets.len)),
                });
            }

            if (std.mem.eql(u8, request.cmd, "action")) {
                if (request.argv.len == 0) return error.InvalidArguments;
                const targets = try self.selectTargets(request, .many);
                defer self.alloc.free(targets);

                return protocol.encodeOk(self.alloc, .{
                    .performed = @as(u32, @intCast(targets.len)),
                });
            }

            if (command.parse(request.cmd)) |cmd| {
                return switch (cmd) {
                    .create_marker => protocol.encodeOk(self.alloc, .{ .created = @as(u32, 1) }),
                    .remove_marker => protocol.encodeOk(self.alloc, .{ .removed = @as(u32, 1) }),
                    .detach_tab, .detach_window => protocol.encodeOk(self.alloc, .{ .detached = @as(u32, 1) }),
                    .disable_ligatures => protocol.encodeOk(self.alloc, .{ .updated = @as(u32, 1) }),
                    .env, .set_user_vars => protocol.encodeOk(self.alloc, .{ .updated = @as(u32, 1) }),
                    .focus_tab => protocol.encodeOk(self.alloc, .{ .focused = @as(u32, 1) }),
                    .get_colors => protocol.encodeOk(self.alloc, .{ .colors = .{} }),
                    .get_text => protocol.encodeOk(self.alloc, .{ .text = "" }),
                    .goto_layout, .last_used_layout => protocol.encodeOk(self.alloc, .{ .switched = @as(u32, 1) }),
                    .kitten => protocol.encodeOk(self.alloc, .{ .started = @as(u32, 1) }),
                    .load_config => protocol.encodeOk(self.alloc, .{ .reloaded = @as(u32, 1) }),
                    .move_os_window => protocol.encodeOk(self.alloc, .{ .moved = @as(u32, 1) }),
                    .maximize_os_window => protocol.encodeOk(self.alloc, .{ .maximized = @as(u32, 1) }),
                    .minimize_os_window => protocol.encodeOk(self.alloc, .{ .minimized = @as(u32, 1) }),
                    .hide_os_window => protocol.encodeOk(self.alloc, .{ .hidden = @as(u32, 1) }),
                    .snap_os_window => protocol.encodeOk(self.alloc, .{ .snapped = @as(u32, 1) }),
                    .resize_os_window, .resize_window => protocol.encodeOk(self.alloc, .{ .resized = @as(u32, 1) }),
                    .run => protocol.encodeOk(self.alloc, .{ .started = @as(u32, 1) }),
                    .scroll_window => protocol.encodeOk(self.alloc, .{ .scrolled = @as(u32, 1) }),
                    .send_key => protocol.encodeOk(self.alloc, .{ .sent = @as(u32, 1) }),
                    .set_background_image,
                    .set_background_opacity,
                    .set_colors,
                    .set_enabled_layouts,
                    .set_font_size,
                    .set_spacing,
                    .set_tab_color,
                    .set_window_logo,
                    => protocol.encodeOk(self.alloc, .{ .updated = @as(u32, 1) }),
                    .signal_child => protocol.encodeOk(self.alloc, .{
                        .signaled = @as(u32, 1),
                    }),

                    // Explicitly handled above.
                    .action,
                    .close_tab,
                    .close_window,
                    .focus_window,
                    .launch,
                    .ls,
                    .new_tab,
                    .new_window,
                    .select_window,
                    .send_text,
                    .set_tab_title,
                    .set_window_title,
                    => unreachable,
                };
            }

            return error.UnsupportedCommand;
        }

        fn selectTargets(
            self: *@This(),
            request: protocol.Request,
            mode: SelectMode,
        ) (Allocator.Error || DispatchError)![]u64 {
            if (self.windows.items.len == 0) return error.NoSurfaces;

            var out: std.ArrayList(u64) = .empty;
            defer out.deinit(self.alloc);

            if (request.all) {
                for (self.windows.items) |window| try out.append(self.alloc, window.id);
                if (mode == .single and out.items.len > 1) return error.AmbiguousMatch;
                return out.toOwnedSlice(self.alloc);
            }

            if (request.match) |expr| {
                for (self.windows.items) |window| {
                    const matched = matcher.matches(expr, .{
                        .id = window.id,
                        .title = window.title,
                        .focused = self.focused != null and self.focused.? == window.id,
                        .recent_rank = self.recentRank(window.last_focus),
                    }) catch |err| switch (err) {
                        error.InvalidExpression,
                        error.InvalidNumber,
                        => return error.InvalidMatchExpression,
                    };
                    if (matched) try out.append(self.alloc, window.id);
                }

                if (out.items.len == 0) return error.NoMatch;
                if (mode == .single and out.items.len > 1) return error.AmbiguousMatch;
                return out.toOwnedSlice(self.alloc);
            }

            if (self.focused) |id| {
                if (self.windowIndexById(id) != null) {
                    try out.append(self.alloc, id);
                    return out.toOwnedSlice(self.alloc);
                }
            }

            try out.append(self.alloc, self.windows.items[0].id);
            return out.toOwnedSlice(self.alloc);
        }

        fn windowIndexById(self: *@This(), id: u64) ?usize {
            for (self.windows.items, 0..) |window, i| {
                if (window.id == id) return i;
            }
            return null;
        }

        fn focusWindow(self: *@This(), id: u64) void {
            const idx = self.windowIndexById(id) orelse return;
            self.focused = id;
            self.windows.items[idx].last_focus = self.focus_epoch;
            self.focus_epoch += 1;
        }

        fn recentRank(self: *@This(), last_focus: u64) u64 {
            if (last_focus == 0) return @as(u64, @intCast(self.windows.items.len + 1));

            var rank: u64 = 1;
            for (self.windows.items) |window| {
                if (window.last_focus > last_focus) rank += 1;
            }
            return rank;
        }

        fn removeWindowById(self: *@This(), id: u64) bool {
            const idx = self.windowIndexById(id) orelse return false;

            const removed = self.windows.swapRemove(idx);
            self.alloc.free(removed.title);

            if (self.focused != null and self.focused.? == id) {
                self.focused = if (self.windows.items.len > 0) self.windows.items[0].id else null;
            }
            return true;
        }
        fn joinArgs(alloc: Allocator, args: []const []const u8) Allocator.Error![]u8 {
            if (args.len == 0) return try alloc.dupe(u8, "");
            if (args.len == 1) return try alloc.dupe(u8, args[0]);
            return try std.mem.join(alloc, " ", args);
        }
    };

    const Helpers = struct {
        fn sendAndParse(
            alloc: Allocator,
            target: []const u8,
            request: protocol.Request,
        ) !std.json.Parsed(std.json.Value) {
            const encoded = try protocol.encodeRequest(alloc, request);
            defer alloc.free(encoded);

            const raw = try transport.request(alloc, target, encoded);
            defer alloc.free(raw);

            return std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
        }
    };

    var mock: Mock = .{
        .alloc = gpa_alloc,
    };
    defer mock.deinit();

    const path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/jterm-matrix-{d}.sock",
        .{std.time.milliTimestamp()},
    );
    defer testing.allocator.free(path);

    var server = try Server.init(
        gpa_alloc,
        .{
            .userdata = &mock,
            .submitFn = Mock.submit,
        },
        path,
    );
    defer server.deinit();
    try server.start();

    std.Thread.sleep(10 * std.time.ns_per_ms);

    const target = try std.fmt.allocPrint(
        testing.allocator,
        "unix:{s}",
        .{path},
    );
    defer testing.allocator.free(target);

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "ls" });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(usize, 0), obj.get("data").?.object.get("surfaces").?.array.items.len);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "new-window" });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(i64, 1), obj.get("data").?.object.get("created").?.integer);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "launch" });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(i64, 1), obj.get("data").?.object.get("created").?.integer);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "focus-window", .match = "id:1" });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "set-window-title",
            .match = "id:1",
            .argv = &.{ "main", "shell" },
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(i64, 1), obj.get("data").?.object.get("updated").?.integer);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "send-text",
            .match = "state:focused",
            .argv = &.{ "echo", "hi" },
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(i64, 1), obj.get("data").?.object.get("sent").?.integer);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "action",
            .match = "recent:1",
            .argv = &.{"clear_screen"},
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(i64, 1), obj.get("data").?.object.get("performed").?.integer);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "close-tab",
            .match = "id:2",
            .argv = &.{"this"},
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(i64, 1), obj.get("data").?.object.get("closed").?.integer);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "launch" });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "focus-window",
            .all = true,
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(!obj.get("ok").?.bool);
        try testing.expectEqualStrings(
            "match expression resolved to multiple targets",
            obj.get("error").?.string,
        );
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "focus-window",
            .match = "id:999",
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(!obj.get("ok").?.bool);
        try testing.expectEqualStrings(
            "no target matched the request",
            obj.get("error").?.string,
        );
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "focus-window",
            .match = "id:abc",
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(!obj.get("ok").?.bool);
        try testing.expectEqualStrings(
            "invalid match expression",
            obj.get("error").?.string,
        );
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
            .cmd = "close-window",
            .all = true,
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(i64, 2), obj.get("data").?.object.get("closed").?.integer);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "ls" });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ok").?.bool);
        try testing.expectEqual(@as(usize, 0), obj.get("data").?.object.get("surfaces").?.array.items.len);
    }

    {
        var parsed = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "no-such-command" });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(!obj.get("ok").?.bool);
        try testing.expectEqualStrings(
            "unsupported remote-control command",
            obj.get("error").?.string,
        );
    }

    {
        var seeded = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "new-window" });
        seeded.deinit();

        inline for (command.all) |cmd| {
            var ensured = try Helpers.sendAndParse(testing.allocator, target, .{ .cmd = "new-window" });
            ensured.deinit();

            const argv: []const []const u8 = switch (cmd) {
                .action => &.{"clear_screen"},
                .close_tab => &.{"this"},
                .create_marker => &.{"prompt"},
                .env => &.{"SYMPH_WINDOW=demo"},
                .focus_tab => &.{"1"},
                .goto_layout => &.{"stack"},
                .kitten => &.{"icat"},
                .move_os_window => &.{"--monitor=m2"},
                .maximize_os_window => &.{"--monitor=m1"},
                .minimize_os_window => &.{},
                .hide_os_window => &.{},
                .remove_marker => &.{"prompt"},
                .snap_os_window => &.{ "left", "--monitor=m1" },
                .resize_os_window => &.{"80x24"},
                .resize_window => &.{ "wider", "1" },
                .run => &.{ "echo", "hi" },
                .scroll_window => &.{"1"},
                .send_key => &.{"enter"},
                .set_background_image => &.{"/tmp/bg.png"},
                .set_background_opacity => &.{"0.9"},
                .set_colors => &.{"foreground=#ffffff"},
                .set_enabled_layouts => &.{"splits,stack"},
                .set_font_size => &.{"13"},
                .set_spacing => &.{"padding=6"},
                .set_tab_color => &.{"#00ff00"},
                .set_tab_title => &.{"tab"},
                .set_user_vars => &.{"role=worker"},
                .set_window_logo => &.{"/tmp/logo.png"},
                .set_window_title => &.{"win"},
                .signal_child => &.{"SIGTERM"},
                .send_text => &.{"echo hi"},
                else => &.{},
            };

            var parsed = try Helpers.sendAndParse(testing.allocator, target, .{
                .cmd = command.name(cmd),
                .argv = argv,
            });
            defer parsed.deinit();

            const obj = parsed.value.object;
            try testing.expect(obj.get("ok").?.bool);
        }
    }
}
