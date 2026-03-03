const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../config.zig");
const remote = @import("../remote/main.zig");

pub const Options = struct {
    const UsePassword = enum {
        if_available,
        always,
        never,
    };

    /// Remote control target endpoint.
    to: ?[]const u8 = null,

    /// Match expression to select target surfaces/windows.
    match: ?[]const u8 = null,
    match_tab: ?[]const u8 = null,

    /// Apply the command to all matching targets.
    all: bool = false,
    ignore_no_match: bool = false,

    /// Optional remote control password.
    password: ?[]const u8 = null,
    password_file: ?[]const u8 = null,
    password_env: ?[]const u8 = null,
    use_password: UsePassword = .if_available,

    /// Send command without expecting a response.
    @"no-response": bool = false,

    /// Force a response body even if config defaults to no-response.
    response: bool = false,

    /// Command-level response timeout hint (seconds).
    response_timeout: ?u32 = null,
};

const ParseError = error{
    MarkerNotFound,
    MissingCommand,
    MissingValue,
    UnknownOption,
    InvalidValue,
    HelpRequested,
};

const Invocation = struct {
    options: Options,
    command_name: []const u8,
    command_args: []const []const u8,

    _owned_command_args: ?[]const []const u8 = null,

    fn deinit(self: *Invocation, alloc: Allocator) void {
        if (self._owned_command_args) |v| alloc.free(v);
        self.* = undefined;
    }
};

/// Run kitty-compatible remote control commands.
///
/// This command is an initial compatibility entrypoint for kitty-style
/// invocations (`jterm @ <command>`). Commands are sent over a local
/// unix socket to a running `jterm` instance.
///
/// Flags:
///
///   * `--to=unix:/path/to/socket`: Remote control target socket.
///   * `--match=<expression>`: Match expression (id/title/cwd/state/recent).
///   * `--all`: Apply command to all matching targets.
///   * `--password=<token>`: Optional authorization token.
///   * `--no-response`: Send request without requiring a response body.
///   * `--response`: Force printing a response body.
///
/// Available since: 1.6.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    while (iter.next()) |arg| {
        try argv.append(alloc, arg);
    }

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgv(alloc, argv.items, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgv(
    alloc: Allocator,
    argv: []const []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    if (findMarker(argv) != null and hasHelpFlag(argv)) {
        try printHelpForInvocation(argv);
        return 0;
    }

    var invocation = parseInvocation(alloc, argv) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelpForInvocation(argv);
            return 0;
        },
        error.MarkerNotFound => {
            try stderr.print("No remote-control marker found. Use `jterm @ <command>`.\n", .{});
            return 1;
        },
        error.MissingCommand => {
            try stderr.print("No remote-control command was provided.\n", .{});
            return 1;
        },
        error.MissingValue => {
            try stderr.print("A required option value is missing.\n", .{});
            return 1;
        },
        error.UnknownOption => {
            try stderr.print("Unknown remote-control option.\n", .{});
            return 1;
        },
        error.InvalidValue => {
            try stderr.print("Invalid remote-control option value.\n", .{});
            return 1;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer invocation.deinit(alloc);

    var password_owned: ?[]u8 = null;
    defer if (password_owned) |v| alloc.free(v);

    var password = invocation.options.password;
    if (invocation.options.use_password == .never) {
        password = null;
    } else if (password == null) {
        if (invocation.options.password_file) |path| {
            password_owned = readPasswordFile(alloc, path) catch {
                try stderr.print("Failed to read remote-control password file.\n", .{});
                return 1;
            };
            password = std.mem.trimRight(u8, password_owned.?, " \r\n\t");
        } else if (invocation.options.password_env) |env_name| {
            const env_value = std.posix.getenv(env_name) orelse {
                try stderr.print("Remote-control password environment variable is not set.\n", .{});
                return 1;
            };
            password = std.mem.sliceTo(env_value, 0);
        }
    }

    if (invocation.options.use_password == .always and (password == null or password.?.len == 0)) {
        try stderr.print("Remote-control password is required (`--use-password=always`).\n", .{});
        return 1;
    }

    const no_response = computeNoResponse(
        invocation.options,
        invocation.command_name,
        defaultNoResponse(alloc),
    );

    const target = invocation.options.to orelse
        if (std.posix.getenv("JTERM_LISTEN_ON")) |v|
            std.mem.sliceTo(v, 0)
        else
            "unix:/tmp/jterm.sock";

    const use_password_transport = invocation.options.use_password != .never and
        password != null and
        password.?.len > 0;
    const timestamp_ns: ?i64 = if (use_password_transport) @intCast(std.time.nanoTimestamp()) else null;

    const request = try remote.protocol.encodeRequest(
        alloc,
        .{
            .cmd = invocation.command_name,
            .argv = invocation.command_args,
            .match = invocation.options.match,
            .match_tab = invocation.options.match_tab,
            .all = invocation.options.all,
            .ignore_no_match = invocation.options.ignore_no_match,
            .no_response = no_response,
            .password = password,
            .timestamp = timestamp_ns,
            .response_timeout = invocation.options.response_timeout,
        },
    );
    defer alloc.free(request);

    var encrypted_request: ?[]u8 = null;
    defer if (encrypted_request) |payload| alloc.free(payload);
    const request_payload = payload: {
        if (!use_password_transport) break :payload request;

        const encoded_key = if (std.posix.getenv("KITTY_PUBLIC_KEY")) |v|
            std.mem.sliceTo(v, 0)
        else if (std.posix.getenv("JTERM_PUBLIC_KEY")) |v|
            std.mem.sliceTo(v, 0)
        else {
            try stderr.print("Remote-control password mode requires KITTY_PUBLIC_KEY.\n", .{});
            return 1;
        };

        const parsed_key = remote.protocol.decodeKittyPublicKey(alloc, encoded_key) catch {
            try stderr.print("Invalid KITTY_PUBLIC_KEY value.\n", .{});
            return 1;
        };
        encrypted_request = remote.protocol.encryptRequestForServer(alloc, request, parsed_key.public_key) catch {
            try stderr.print("Failed to encrypt password-authenticated request.\n", .{});
            return 1;
        };
        break :payload encrypted_request.?;
    };

    const response = remote.transport.request(
        alloc,
        target,
        request_payload,
    ) catch |err| switch (err) {
        error.InvalidTarget => {
            try stderr.print("`--to` must use unix socket format `unix:/path`.\n", .{});
            return 1;
        },
        error.EmptyResponse => {
            if (no_response) return 0;
            try stderr.print("Remote-control server returned an empty response.\n", .{});
            return 1;
        },
        error.ResponseTooLarge => {
            try stderr.print("Remote-control response exceeded maximum allowed size.\n", .{});
            return 1;
        },
        else => {
            try stderr.print("Remote-control transport failure: {}\n", .{err});
            return 1;
        },
    };
    defer alloc.free(response);

    var parsed_response = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch null;
    defer if (parsed_response) |*parsed| parsed.deinit();

    if (parsed_response) |*parsed| {
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("ok")) |ok_value| {
                if (ok_value == .bool and !ok_value.bool) {
                    const err_message = if (obj.get("error")) |err_value|
                        switch (err_value) {
                            .string => err_value.string,
                            else => "remote-control command failed",
                        }
                    else
                        "remote-control command failed";
                    try stderr.print("Error: {s}\n", .{err_message});
                    return 1;
                }
            }
        }
    }

    if (!no_response) {
        var stdout_buffer: [64 * 1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;

        if (invocation.options.response) {
            try stdout.print("{s}\n", .{response});
        } else if (parsed_response) |*parsed| {
            try printCommandOutput(alloc, stdout, invocation.command_name, parsed.value);
        } else if (response.len > 0) {
            try stdout.print("{s}\n", .{response});
        }

        try stdout.flush();
    }

    return 0;
}

fn parseInvocation(
    alloc: Allocator,
    argv: []const []const u8,
) (Allocator.Error || ParseError)!Invocation {
    const marker_index = findMarker(argv) orelse return error.MarkerNotFound;

    var options: Options = .{};
    var command_name: ?[]const u8 = null;
    var command_args_started = false;

    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(alloc);

    var i: usize = marker_index + 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            if (command_name == null or !command_args_started) return error.HelpRequested;
        }

        if (std.mem.eql(u8, arg, "--")) {
            if (command_name == null) continue;
            const tail = argv[i + 1 ..];
            if (tail.len > 0) try command_args.appendSlice(alloc, tail);
            break;
        }

        const should_parse_global = command_name == null;
        if (should_parse_global and try parseGlobalOption(argv, &i, &options, arg, false)) {
            continue;
        }
        if (should_parse_global and try parseCommandOption(argv, &i, &options, arg, false)) {
            continue;
        }

        const should_parse_command_options = command_name != null and !command_args_started;
        if (should_parse_command_options and try parseCommandOption(argv, &i, &options, arg, false)) {
            continue;
        }

        if (command_name == null and std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        }

        if (command_name == null) {
            command_name = arg;
            continue;
        }

        try command_args.append(alloc, arg);
        command_args_started = true;
    }

    const command = command_name orelse return error.MissingCommand;
    const has_command_args = command_args.items.len > 0;
    const args: []const []const u8 = if (!has_command_args)
        &.{}
    else
        try command_args.toOwnedSlice(alloc);

    return .{
        .options = options,
        .command_name = command,
        .command_args = args,
        ._owned_command_args = if (!has_command_args) null else args,
    };
}

fn parseGlobalOption(
    argv: []const []const u8,
    i: *usize,
    options: *Options,
    arg: []const u8,
    strict_unknown: bool,
) ParseError!bool {
    if (std.mem.startsWith(u8, arg, "--to=")) {
        options.to = try requireValue(arg["--to=".len..]);
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--password=")) {
        options.password = try requireValue(arg["--password=".len..]);
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--password-file=")) {
        options.password_file = try requireValue(arg["--password-file=".len..]);
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--password-env=")) {
        options.password_env = try requireValue(arg["--password-env=".len..]);
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--use-password=")) {
        options.use_password = try parseUsePassword(arg["--use-password=".len..]);
        return true;
    }

    if (std.mem.eql(u8, arg, "--to") or
        std.mem.eql(u8, arg, "--password") or
        std.mem.eql(u8, arg, "--password-file") or
        std.mem.eql(u8, arg, "--password-env") or
        std.mem.eql(u8, arg, "--use-password"))
    {
        const next = i.* + 1;
        if (next >= argv.len) return error.MissingValue;
        i.* = next;

        const value = try requireValue(argv[next]);
        if (std.mem.eql(u8, arg, "--to")) options.to = value;
        if (std.mem.eql(u8, arg, "--password")) options.password = value;
        if (std.mem.eql(u8, arg, "--password-file")) options.password_file = value;
        if (std.mem.eql(u8, arg, "--password-env")) options.password_env = value;
        if (std.mem.eql(u8, arg, "--use-password")) options.use_password = try parseUsePassword(value);
        return true;
    }

    if (strict_unknown and std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;

    return false;
}

fn parseCommandOption(
    argv: []const []const u8,
    i: *usize,
    options: *Options,
    arg: []const u8,
    strict_unknown: bool,
) ParseError!bool {
    if (std.mem.eql(u8, arg, "--no-response")) {
        @field(options.*, "no-response") = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--response")) {
        options.response = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--all")) {
        options.all = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--ignore-no-match")) {
        options.ignore_no_match = true;
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--match=")) {
        options.match = try requireValue(arg["--match=".len..]);
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--response-timeout=")) {
        const value = try requireValue(arg["--response-timeout=".len..]);
        options.response_timeout = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidValue;
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--match-tab=")) {
        options.match_tab = try requireValue(arg["--match-tab=".len..]);
        return true;
    }

    if (std.mem.eql(u8, arg, "--match") or
        std.mem.eql(u8, arg, "--match-tab") or
        std.mem.eql(u8, arg, "--response-timeout"))
    {
        const next = i.* + 1;
        if (next >= argv.len) return error.MissingValue;
        i.* = next;
        const value = try requireValue(argv[next]);
        if (std.mem.eql(u8, arg, "--match")) options.match = value;
        if (std.mem.eql(u8, arg, "--match-tab")) options.match_tab = value;
        if (std.mem.eql(u8, arg, "--response-timeout")) {
            options.response_timeout = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidValue;
        }
        return true;
    }

    if (strict_unknown and std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
    return false;
}

fn requireValue(value: []const u8) ParseError![]const u8 {
    if (value.len == 0) return error.MissingValue;
    return value;
}

fn parseUsePassword(value: []const u8) ParseError!Options.UsePassword {
    if (std.mem.eql(u8, value, "if-available")) return .if_available;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.InvalidValue;
}

fn readPasswordFile(
    alloc: Allocator,
    path: []const u8,
) ![]u8 {
    const max_password_file_size = 8 * 1024;
    return try std.fs.cwd().readFileAlloc(alloc, path, max_password_file_size);
}

fn findMarker(argv: []const []const u8) ?usize {
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "@")) return i;
        if (std.mem.eql(u8, arg, "+remote-control")) return i;
    }

    return null;
}

fn defaultNoResponse(alloc: Allocator) bool {
    var config = configpkg.Config.load(alloc) catch return false;
    defer config.deinit();
    return config.@"remote-control-default-no-response";
}

fn commandForcesResponse(command_name: []const u8) bool {
    if (std.mem.eql(u8, command_name, "ls")) return true;
    if (std.mem.eql(u8, command_name, "new-window")) return true;
    if (std.mem.eql(u8, command_name, "new-tab")) return true;
    if (std.mem.eql(u8, command_name, "launch")) return true;
    if (std.mem.eql(u8, command_name, "run")) return true;
    if (std.mem.eql(u8, command_name, "get-colors")) return true;
    if (std.mem.eql(u8, command_name, "get-text")) return true;
    if (std.mem.eql(u8, command_name, "select-window")) return true;
    return false;
}

fn computeNoResponse(
    options: Options,
    command_name: []const u8,
    default_no_response: bool,
) bool {
    if (options.response) return false;
    if (@field(options, "no-response")) return true;
    if (commandForcesResponse(command_name)) return false;
    return default_no_response;
}

fn printCommandOutput(
    alloc: Allocator,
    stdout: *std.Io.Writer,
    command_name: []const u8,
    value: std.json.Value,
) !void {
    if (value != .object) return;
    const obj = value.object;
    const data = obj.get("data") orelse return;

    if (std.mem.eql(u8, command_name, "ls")) {
        const out = try std.json.Stringify.valueAlloc(alloc, data, .{});
        defer alloc.free(out);
        try stdout.print("{s}\n", .{out});
        return;
    }

    if (std.mem.eql(u8, command_name, "new-window") or
        std.mem.eql(u8, command_name, "new-tab") or
        std.mem.eql(u8, command_name, "launch"))
    {
        if (data == .object) {
            const data_obj = data.object;
            if (data_obj.get("id")) |id_value| {
                switch (id_value) {
                    .integer => try stdout.print("{d}\n", .{id_value.integer}),
                    .float => try stdout.print("{d}\n", .{@as(i64, @intFromFloat(id_value.float))}),
                    else => {},
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, command_name, "run")) {
        if (data == .object) {
            const data_obj = data.object;
            if (data_obj.get("stdout")) |stdout_value| {
                if (stdout_value == .string and stdout_value.string.len > 0) {
                    try stdout.writeAll(stdout_value.string);
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, command_name, "select-window")) {
        if (data == .object) {
            const data_obj = data.object;
            if (data_obj.get("focused")) |focused| {
                if (focused == .bool and focused.bool) {
                    try stdout.writeAll("1\n");
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, command_name, "get-text")) {
        if (data == .object) {
            const data_obj = data.object;
            if (data_obj.get("text")) |text_value| {
                if (text_value == .string and text_value.string.len > 0) {
                    try stdout.writeAll(text_value.string);
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, command_name, "get-colors")) {
        if (data == .object) {
            const data_obj = data.object;
            if (data_obj.get("colors")) |colors_value| {
                switch (colors_value) {
                    .string => |s| if (s.len > 0) try stdout.print("{s}\n", .{s}),
                    .array => |arr| {
                        for (arr.items) |item| {
                            if (item == .string) try stdout.print("{s}\n", .{item.string});
                        }
                    },
                    else => {},
                }
            }
        }
        return;
    }
}

fn hasHelpFlag(argv: []const []const u8) bool {
    const marker = findMarker(argv) orelse return false;
    for (argv[marker + 1 ..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn printHelpForInvocation(argv: []const []const u8) !void {
    const marker = findMarker(argv) orelse return;
    const command_name = detectCommandForHelp(argv[marker + 1 ..]);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (command_name) |cmd| {
        try printCommandHelp(stdout, cmd);
    } else {
        try printGlobalHelp(stdout);
    }

    try stdout.flush();
}

fn detectCommandForHelp(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) continue;
        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }

        if (std.mem.eql(u8, arg, "--to") or
            std.mem.eql(u8, arg, "--match") or
            std.mem.eql(u8, arg, "--match-tab") or
            std.mem.eql(u8, arg, "--password") or
            std.mem.eql(u8, arg, "--password-file") or
            std.mem.eql(u8, arg, "--password-env") or
            std.mem.eql(u8, arg, "--use-password"))
        {
            if (i + 1 < args.len) i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) continue;
        return arg;
    }

    return null;
}

fn printGlobalHelp(stdout: *std.Io.Writer) !void {
    try stdout.writeAll(
        \\Usage: jterm @ [global options] [sub-command] [sub-command options] [sub-command args]
        \\
        \\Control jterm by sending it commands. Set allow-remote-control=true
        \\for this to work.
        \\
        \\Commands:
        \\
    );

    inline for (remote.command.all) |cmd| {
        try stdout.print("  {s}\n", .{remote.command.name(cmd)});
    }

    try stdout.writeAll(
        \\
        \\Global options:
        \\  --to
        \\  --password
        \\  --password-file [=rc-pass]
        \\  --password-env [=KITTY_RC_PASSWORD]
        \\  --use-password [=if-available]
        \\  --help, -h [=no]
        \\
        \\Get help for an individual command by running:
        \\  jterm @ <command> --help
        \\
    );
}

fn printCommandHelp(stdout: *std.Io.Writer, command_name: []const u8) !void {
    try stdout.print("Usage: jterm @ {s} [options]\n\n", .{command_name});
    try stdout.writeAll("Options:\n");

    for (all_help_option_tokens) |token| {
        try stdout.print("  {s}\n", .{token});
    }
}

const all_help_option_tokens = [_][]const u8{
    "--action",
    "--add-cursor",
    "--add-to-session",
    "--add-wrap-markers",
    "--all",
    "--all-env-vars",
    "--allow-remote-control",
    "--alpha",
    "--ansi",
    "--axis",
    "--bias",
    "--bracketed-paste",
    "--clear-selection",
    "--color",
    "--configured",
    "--copy-cmdline",
    "--copy-colors",
    "--copy-env",
    "--cwd",
    "--dont-take-focus",
    "--env",
    "--exclude-active",
    "--extent",
    "--from-file",
    "--height",
    "--help",
    "--hold",
    "--hold-after-ssh",
    "--ignore-no-match",
    "--ignore-overrides",
    "--increment",
    "--incremental",
    "--keep-focus",
    "--layout",
    "--location",
    "--logo",
    "--logo-alpha",
    "--logo-position",
    "--marker",
    "--match",
    "--match-tab",
    "--monitor",
    "--new-tab",
    "--next-to",
    "--no-response",
    "--os-panel",
    "--os-window-class",
    "--os-window-name",
    "--os-window-state",
    "--os-window-title",
    "--output-format",
    "--override",
    "--password",
    "--password-env",
    "--password-file",
    "--position",
    "--reactivate-prev-tab",
    "--remote-control-password",
    "--reset",
    "--response-timeout",
    "--self",
    "--source-window",
    "--spacing",
    "--stay-in-tab",
    "--stdin",
    "--stdin-add-formatting",
    "--stdin-add-line-wrap-markers",
    "--stdin-source",
    "--tab-title",
    "--target-tab",
    "--temporary",
    "--title",
    "--to",
    "--toggle",
    "--type",
    "--unit",
    "--use-password",
    "--var",
    "--wait-for-child-to-exit",
    "--watcher",
    "--width",
    "--window-title",
    "--window-type",
};

test "parseInvocation parses @ form with command" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "--to=unix:/tmp/jterm.sock",
        "ls",
    };
    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expectEqualStrings("unix:/tmp/jterm.sock", invocation.options.to.?);
    try testing.expectEqualStrings("ls", invocation.command_name);
    try testing.expectEqual(@as(usize, 0), invocation.command_args.len);
}

test "parseInvocation parses +remote-control form" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "+remote-control",
        "--password=token",
        "ls",
    };
    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expectEqualStrings("token", invocation.options.password.?);
    try testing.expectEqualStrings("ls", invocation.command_name);
}

test "parseInvocation parses match and all options" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "send-text",
        "--match=id:4",
        "--all",
        "hello",
    };
    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expectEqualStrings("id:4", invocation.options.match.?);
    try testing.expect(invocation.options.all);
    try testing.expectEqualStrings("send-text", invocation.command_name);
    try testing.expectEqual(@as(usize, 1), invocation.command_args.len);
    try testing.expectEqualStrings("hello", invocation.command_args[0]);
}

test "parseInvocation parses match-tab and ignore-no-match options" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "send-text",
        "--match-tab=title:demo",
        "--ignore-no-match",
        "hello",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expectEqualStrings("title:demo", invocation.options.match_tab.?);
    try testing.expect(invocation.options.ignore_no_match);
}

test "parseInvocation consumes response-timeout command option" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "--to=unix:/tmp/jterm.sock",
        "select-window",
        "--response-timeout=1",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expectEqualStrings("select-window", invocation.command_name);
    try testing.expectEqual(@as(usize, 0), invocation.command_args.len);
    try testing.expectEqual(@as(u32, 1), invocation.options.response_timeout.?);
}

test "parseInvocation parses password source options" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "--password-file=/tmp/jterm-pass.txt",
        "--password-env=JTERM_PASS",
        "--use-password=always",
        "ls",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/jterm-pass.txt", invocation.options.password_file.?);
    try testing.expectEqualStrings("JTERM_PASS", invocation.options.password_env.?);
    try testing.expectEqual(Options.UsePassword.always, invocation.options.use_password);
}

test "parseInvocation handles no-response" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "ls",
        "--no-response",
    };
    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expect(@field(invocation.options, "no-response"));
}

test "parseInvocation handles response flag" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "ls",
        "--response",
    };
    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expect(invocation.options.response);
}

test "parseInvocation errors when command is missing" {
    const testing = std.testing;

    const argv = [_][]const u8{ "jterm", "@", "--to=unix:/tmp/jterm.sock" };
    try testing.expectError(error.MissingCommand, parseInvocation(testing.allocator, argv[0..]));
}

test "parseInvocation supports global options after command" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "focus-window",
        "--match=env:SYMPH_WINDOW=^demo$",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);

    try testing.expectEqualStrings("focus-window", invocation.command_name);
    try testing.expectEqualStrings("env:SYMPH_WINDOW=^demo$", invocation.options.match.?);
    try testing.expectEqual(@as(usize, 0), invocation.command_args.len);
}

test "parseInvocation supports command options before command" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "--response",
        "--match=recent:0",
        "ls",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);

    try testing.expect(invocation.options.response);
    try testing.expectEqualStrings("recent:0", invocation.options.match.?);
    try testing.expectEqualStrings("ls", invocation.command_name);
}

test "parseInvocation keeps launch options as command args" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "launch",
        "--type=os-window",
        "--title=symph: demo",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);

    try testing.expectEqualStrings("launch", invocation.command_name);
    try testing.expectEqual(@as(usize, 2), invocation.command_args.len);
    try testing.expectEqualStrings("--type=os-window", invocation.command_args[0]);
    try testing.expectEqualStrings("--title=symph: demo", invocation.command_args[1]);
}

test "parseInvocation does not consume global options after command args start" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "launch",
        "bash",
        "--match",
        "literal",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);

    try testing.expectEqualStrings("launch", invocation.command_name);
    try testing.expectEqual(@as(usize, 3), invocation.command_args.len);
    try testing.expectEqualStrings("bash", invocation.command_args[0]);
    try testing.expectEqualStrings("--match", invocation.command_args[1]);
    try testing.expectEqualStrings("literal", invocation.command_args[2]);
    try testing.expect(invocation.options.match == null);
}

test "parseInvocation rejects invalid use-password value" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "--use-password=sometimes",
        "ls",
    };

    try testing.expectError(error.InvalidValue, parseInvocation(testing.allocator, argv[0..]));
}

fn expectOptionalStringEqual(expected: ?[]const u8, actual: ?[]const u8) !void {
    const testing = std.testing;

    if (expected == null or actual == null) {
        try testing.expect(expected == null and actual == null);
        return;
    }

    try testing.expectEqualStrings(expected.?, actual.?);
}

fn expectOptionsEqual(expected: Options, actual: Options) !void {
    const testing = std.testing;

    try expectOptionalStringEqual(expected.to, actual.to);
    try expectOptionalStringEqual(expected.match, actual.match);
    try expectOptionalStringEqual(expected.match_tab, actual.match_tab);
    try testing.expectEqual(expected.all, actual.all);
    try testing.expectEqual(expected.ignore_no_match, actual.ignore_no_match);
    try expectOptionalStringEqual(expected.password, actual.password);
    try expectOptionalStringEqual(expected.password_file, actual.password_file);
    try expectOptionalStringEqual(expected.password_env, actual.password_env);
    try testing.expectEqual(expected.use_password, actual.use_password);
    try testing.expectEqual(@field(expected, "no-response"), @field(actual, "no-response"));
    try testing.expectEqual(expected.response, actual.response);
    try testing.expectEqual(expected.response_timeout, actual.response_timeout);
}

fn parseInvocationFromParts(
    alloc: Allocator,
    pre_command: []const []const u8,
    command_name: []const u8,
    post_command: []const []const u8,
) (Allocator.Error || ParseError)!Invocation {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.appendSlice(alloc, &.{ "jterm", "@" });
    try argv.appendSlice(alloc, pre_command);
    try argv.append(alloc, command_name);
    try argv.appendSlice(alloc, post_command);

    return parseInvocation(alloc, argv.items);
}

test "parseInvocation accepts every remote command name" {
    const testing = std.testing;

    for (remote.command.all) |cmd| {
        const command_name = remote.command.name(cmd);
        var invocation = try parseInvocationFromParts(
            testing.allocator,
            &.{},
            command_name,
            &.{},
        );
        defer invocation.deinit(testing.allocator);

        try testing.expectEqualStrings(command_name, invocation.command_name);
        try testing.expectEqual(@as(usize, 0), invocation.command_args.len);
        try expectOptionsEqual(.{}, invocation.options);
    }
}

test "parseInvocation parses every global option form" {
    const testing = std.testing;

    const Case = struct {
        tokens: []const []const u8,
        expected: Options,
    };

    const cases = [_]Case{
        .{ .tokens = &.{"--to=unix:/tmp/jterm-custom.sock"}, .expected = .{ .to = "unix:/tmp/jterm-custom.sock" } },
        .{ .tokens = &.{ "--to", "unix:/tmp/jterm-custom.sock" }, .expected = .{ .to = "unix:/tmp/jterm-custom.sock" } },
        .{ .tokens = &.{"--password=top-secret"}, .expected = .{ .password = "top-secret" } },
        .{ .tokens = &.{ "--password", "top-secret" }, .expected = .{ .password = "top-secret" } },
        .{ .tokens = &.{"--password-file=/tmp/jterm-pass.txt"}, .expected = .{ .password_file = "/tmp/jterm-pass.txt" } },
        .{ .tokens = &.{ "--password-file", "/tmp/jterm-pass.txt" }, .expected = .{ .password_file = "/tmp/jterm-pass.txt" } },
        .{ .tokens = &.{"--password-env=JTERM_PASS"}, .expected = .{ .password_env = "JTERM_PASS" } },
        .{ .tokens = &.{ "--password-env", "JTERM_PASS" }, .expected = .{ .password_env = "JTERM_PASS" } },
        .{ .tokens = &.{"--use-password=if-available"}, .expected = .{ .use_password = .if_available } },
        .{ .tokens = &.{ "--use-password", "if-available" }, .expected = .{ .use_password = .if_available } },
        .{ .tokens = &.{"--use-password=always"}, .expected = .{ .use_password = .always } },
        .{ .tokens = &.{ "--use-password", "always" }, .expected = .{ .use_password = .always } },
        .{ .tokens = &.{"--use-password=never"}, .expected = .{ .use_password = .never } },
        .{ .tokens = &.{ "--use-password", "never" }, .expected = .{ .use_password = .never } },
    };

    for (cases) |case| {
        var invocation = try parseInvocationFromParts(
            testing.allocator,
            case.tokens,
            "ls",
            &.{},
        );
        defer invocation.deinit(testing.allocator);

        try testing.expectEqualStrings("ls", invocation.command_name);
        try testing.expectEqual(@as(usize, 0), invocation.command_args.len);
        try expectOptionsEqual(case.expected, invocation.options);
    }
}

test "parseInvocation parses every command option form before and after command" {
    const testing = std.testing;

    const Case = struct {
        tokens: []const []const u8,
        expected: Options,
    };

    const cases = [_]Case{
        .{ .tokens = &.{"--no-response"}, .expected = .{ .@"no-response" = true } },
        .{ .tokens = &.{"--response"}, .expected = .{ .response = true } },
        .{ .tokens = &.{"--all"}, .expected = .{ .all = true } },
        .{ .tokens = &.{"--ignore-no-match"}, .expected = .{ .ignore_no_match = true } },
        .{ .tokens = &.{"--match=id:4"}, .expected = .{ .match = "id:4" } },
        .{ .tokens = &.{ "--match", "id:4" }, .expected = .{ .match = "id:4" } },
        .{ .tokens = &.{"--match-tab=title:demo"}, .expected = .{ .match_tab = "title:demo" } },
        .{ .tokens = &.{ "--match-tab", "title:demo" }, .expected = .{ .match_tab = "title:demo" } },
        .{ .tokens = &.{"--response-timeout=9"}, .expected = .{ .response_timeout = 9 } },
        .{ .tokens = &.{ "--response-timeout", "9" }, .expected = .{ .response_timeout = 9 } },
    };

    for (cases) |case| {
        var before = try parseInvocationFromParts(
            testing.allocator,
            case.tokens,
            "select-window",
            &.{},
        );
        defer before.deinit(testing.allocator);

        try testing.expectEqualStrings("select-window", before.command_name);
        try testing.expectEqual(@as(usize, 0), before.command_args.len);
        try expectOptionsEqual(case.expected, before.options);

        var after = try parseInvocationFromParts(
            testing.allocator,
            &.{},
            "select-window",
            case.tokens,
        );
        defer after.deinit(testing.allocator);

        try testing.expectEqualStrings("select-window", after.command_name);
        try testing.expectEqual(@as(usize, 0), after.command_args.len);
        try expectOptionsEqual(case.expected, after.options);
    }
}

test "parseInvocation keeps global options after command as command args" {
    const testing = std.testing;

    const cases = [_][]const []const u8{
        &.{"--to=unix:/tmp/jterm-custom.sock"},
        &.{ "--to", "unix:/tmp/jterm-custom.sock" },
        &.{"--password=top-secret"},
        &.{ "--password", "top-secret" },
        &.{"--password-file=/tmp/jterm-pass.txt"},
        &.{ "--password-file", "/tmp/jterm-pass.txt" },
        &.{"--password-env=JTERM_PASS"},
        &.{ "--password-env", "JTERM_PASS" },
        &.{"--use-password=always"},
        &.{ "--use-password", "always" },
    };

    for (cases) |tokens| {
        var invocation = try parseInvocationFromParts(
            testing.allocator,
            &.{},
            "launch",
            tokens,
        );
        defer invocation.deinit(testing.allocator);

        try testing.expectEqualStrings("launch", invocation.command_name);
        try testing.expectEqual(@as(usize, tokens.len), invocation.command_args.len);
        for (tokens, 0..) |token, i| {
            try testing.expectEqualStrings(token, invocation.command_args[i]);
        }
        try expectOptionsEqual(.{}, invocation.options);
    }
}

test "parseInvocation forwards all documented option tokens once argv mode starts" {
    const testing = std.testing;

    for (all_help_option_tokens) |token| {
        var invocation = try parseInvocationFromParts(
            testing.allocator,
            &.{},
            "launch",
            &.{ "bash", token },
        );
        defer invocation.deinit(testing.allocator);

        try testing.expectEqualStrings("launch", invocation.command_name);
        try testing.expectEqual(@as(usize, 2), invocation.command_args.len);
        try testing.expectEqualStrings("bash", invocation.command_args[0]);
        try testing.expectEqualStrings(token, invocation.command_args[1]);
        try expectOptionsEqual(.{}, invocation.options);
    }
}

test "parseInvocation supports all commands with all shared options before command" {
    const testing = std.testing;

    const pre_command = [_][]const u8{
        "--to=unix:/tmp/jterm-custom.sock",
        "--password=top-secret",
        "--password-file=/tmp/jterm-pass.txt",
        "--password-env=JTERM_PASS",
        "--use-password=always",
        "--no-response",
        "--response",
        "--all",
        "--ignore-no-match",
        "--match=id:9",
        "--match-tab=title:demo",
        "--response-timeout=7",
    };

    const expected: Options = .{
        .to = "unix:/tmp/jterm-custom.sock",
        .match = "id:9",
        .match_tab = "title:demo",
        .all = true,
        .ignore_no_match = true,
        .password = "top-secret",
        .password_file = "/tmp/jterm-pass.txt",
        .password_env = "JTERM_PASS",
        .use_password = .always,
        .@"no-response" = true,
        .response = true,
        .response_timeout = 7,
    };

    for (remote.command.all) |cmd| {
        const command_name = remote.command.name(cmd);
        var invocation = try parseInvocationFromParts(
            testing.allocator,
            pre_command[0..],
            command_name,
            &.{},
        );
        defer invocation.deinit(testing.allocator);

        try testing.expectEqualStrings(command_name, invocation.command_name);
        try testing.expectEqual(@as(usize, 0), invocation.command_args.len);
        try expectOptionsEqual(expected, invocation.options);
    }
}

test "parseInvocation supports all commands with command options after command" {
    const testing = std.testing;

    const post_command = [_][]const u8{
        "--no-response",
        "--response",
        "--all",
        "--ignore-no-match",
        "--match=id:9",
        "--match-tab=title:demo",
        "--response-timeout=7",
    };

    const expected: Options = .{
        .match = "id:9",
        .match_tab = "title:demo",
        .all = true,
        .ignore_no_match = true,
        .@"no-response" = true,
        .response = true,
        .response_timeout = 7,
    };

    for (remote.command.all) |cmd| {
        const command_name = remote.command.name(cmd);
        var invocation = try parseInvocationFromParts(
            testing.allocator,
            &.{},
            command_name,
            post_command[0..],
        );
        defer invocation.deinit(testing.allocator);

        try testing.expectEqualStrings(command_name, invocation.command_name);
        try testing.expectEqual(@as(usize, 0), invocation.command_args.len);
        try expectOptionsEqual(expected, invocation.options);
    }
}

test "parseInvocation reports missing values for every value-taking option" {
    const testing = std.testing;

    const Case = struct {
        argv: []const []const u8,
        expected: anyerror,
    };

    const cases = [_]Case{
        .{ .argv = &.{ "jterm", "@", "--to" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password-file" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password-env" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--use-password" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--match" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--match-tab" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--response-timeout" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--to=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password-file=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password-env=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--use-password=" }, .expected = error.InvalidValue },
        .{ .argv = &.{ "jterm", "@", "--match=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--match-tab=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--response-timeout=" }, .expected = error.MissingValue },
    };

    for (cases) |case| {
        try testing.expectError(case.expected, parseInvocation(testing.allocator, case.argv));
    }
}

test "parseInvocation rejects invalid response-timeout values in all forms" {
    const testing = std.testing;

    const cases = [_][]const []const u8{
        &.{ "jterm", "@", "--response-timeout=abc", "ls" },
        &.{ "jterm", "@", "--response-timeout", "abc", "ls" },
        &.{ "jterm", "@", "ls", "--response-timeout=abc" },
        &.{ "jterm", "@", "ls", "--response-timeout", "abc" },
    };

    for (cases) |argv| {
        try testing.expectError(error.InvalidValue, parseInvocation(testing.allocator, argv));
    }
}

test "commandForcesResponse marks output-producing commands" {
    const testing = std.testing;

    try testing.expect(commandForcesResponse("ls"));
    try testing.expect(commandForcesResponse("get-text"));
    try testing.expect(commandForcesResponse("get-colors"));
    try testing.expect(commandForcesResponse("new-window"));
    try testing.expect(commandForcesResponse("run"));
    try testing.expect(!commandForcesResponse("send-text"));
    try testing.expect(!commandForcesResponse("send-key"));
}

test "computeNoResponse honors command response requirements and explicit overrides" {
    const testing = std.testing;

    try testing.expectEqual(false, computeNoResponse(.{}, "ls", true));
    try testing.expectEqual(true, computeNoResponse(.{}, "send-text", true));
    try testing.expectEqual(false, computeNoResponse(.{}, "send-text", false));
    try testing.expectEqual(true, computeNoResponse(.{ .@"no-response" = true }, "ls", false));
    try testing.expectEqual(false, computeNoResponse(.{ .@"no-response" = true, .response = true }, "send-text", true));
}

test "all_help_option_tokens are unique" {
    const testing = std.testing;

    for (all_help_option_tokens, 0..) |token, i| {
        for (all_help_option_tokens[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, token, other));
        }
    }
}

test "printGlobalHelp lists every command name" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try printGlobalHelp(&out.writer);
    const text = try out.toOwnedSlice();
    defer testing.allocator.free(text);

    for (remote.command.all) |cmd| {
        const needle = try std.fmt.allocPrint(testing.allocator, "  {s}\n", .{remote.command.name(cmd)});
        defer testing.allocator.free(needle);
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}

test "printCommandHelp lists every documented option token" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try printCommandHelp(&out.writer, "send-text");
    const text = try out.toOwnedSlice();
    defer testing.allocator.free(text);

    for (all_help_option_tokens) |token| {
        const needle = try std.fmt.allocPrint(testing.allocator, "  {s}\n", .{token});
        defer testing.allocator.free(needle);
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}
