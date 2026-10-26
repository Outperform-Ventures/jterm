const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const remote = @import("../remote/main.zig");
const schema = @import("remote_control_schema.zig");

pub const Options = struct {
    const UsePassword = enum {
        if_available,
        always,
        never,
    };

    const SubmitMode = enum {
        none,
        enter,
        assistant,
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

    /// Optional submit behavior for send-text.
    submit: SubmitMode = .none,
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

const CommandHelp = struct {
    usage: []const u8,
    lines: []const []const u8,
};

const HelpRequest = struct {
    explicit: bool,
    target: ?[]const u8,
};

const LaunchCompatStepResult = union(enum) {
    ok: []u8,
    exit_code: u8,
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
    const explicit_help = detectExplicitHelpRequest(argv);
    if (explicit_help.explicit) {
        try printDetectedHelp(explicit_help.target);
        return 0;
    }

    if (findMarker(argv) != null and hasHelpFlag(argv)) {
        try printHelpForInvocation(argv);
        return 0;
    }

    var invocation = parseInvocation(alloc, argv) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelpForInvocation(argv);
            return @intFromEnum(schema.ExitCode.success);
        },
        error.MarkerNotFound => {
            try stderr.print("No remote-control marker found. Use `jterm @ <command>`.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.MissingCommand => {
            try stderr.print("No remote-control command was provided.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.MissingValue => {
            try stderr.print("A required option value is missing.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.UnknownOption => {
            try stderr.print("Unknown remote-control option.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.InvalidValue => {
            try stderr.print("Invalid remote-control option value.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer invocation.deinit(alloc);

    validateInvocation(stderr, invocation) catch |err| switch (err) {
        error.MissingValue => {
            try stderr.print("Error: a required command option value is missing.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.UnknownOption => {
            try stderr.print("Error: unsupported command option for `{s}`.\n", .{invocation.command_name});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.InvalidValue => {
            try stderr.print("Error: invalid value for `{s}`.\n", .{invocation.command_name});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.MissingArgument => {
            try stderr.print("Error: missing required argument for `{s}`.\n", .{invocation.command_name});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.TooManyArguments => {
            try stderr.print("Error: too many arguments for `{s}`.\n", .{invocation.command_name});
            return @intFromEnum(schema.ExitCode.usage);
        },
    };

    try canonicalizeInvocation(alloc, &invocation);

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

    if (launchCompatEnabled() and std.mem.eql(u8, invocation.command_name, "launch")) {
        return runLaunchCompat(alloc, argv[0], invocation, password, stderr);
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
            build_config.default_remote_control_target;

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

    const response = response: {
        const result = remote.transport.request(
            alloc,
            target,
            request_payload,
        ) catch |err| switch (err) {
            error.InvalidTarget => {
                try stderr.print("`--to` must use unix socket format `unix:/path`.\n", .{});
                return 1;
            },
            error.EmptyResponse => {
                if (no_response) {
                    if (std.mem.eql(u8, invocation.command_name, "send-text") and
                        submitToken(invocation.options.submit) != null)
                    {
                        break :response try alloc.dupe(u8, "");
                    }
                    return @intFromEnum(schema.ExitCode.success);
                }
                try stderr.print("Remote-control server returned an empty response.\n", .{});
                return @intFromEnum(schema.ExitCode.transport);
            },
            error.ResponseTooLarge => {
                try stderr.print("Remote-control response exceeded maximum allowed size.\n", .{});
                return @intFromEnum(schema.ExitCode.transport);
            },
            else => {
                try stderr.print("Remote-control transport failure: {}\n", .{err});
                return @intFromEnum(schema.ExitCode.transport);
            },
        };
        break :response result;
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
                    return classifyRemoteFailure(err_message);
                }
            }
        }
    }

    if (std.mem.eql(u8, invocation.command_name, "send-text")) {
        if (submitToken(invocation.options.submit)) |token| {
            std.Thread.sleep(250 * std.time.ns_per_ms);
            try sendRemoteCommand(
                alloc,
                stderr,
                target,
                invocation.options,
                password,
                "send-key",
                &.{token},
            );
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

    return @intFromEnum(schema.ExitCode.success);
}

fn runLaunchCompat(
    alloc: Allocator,
    executable: []const u8,
    invocation: Invocation,
    password: ?[]const u8,
    stderr: *std.Io.Writer,
) !u8 {
    var parsed = remote.launch.parseArgs(alloc, invocation.command_args) catch |err| switch (err) {
        error.MissingValue => {
            try stderr.print("A required option value is missing.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.InvalidValue, error.InvalidEnv, error.UnsupportedOption => {
            try stderr.print("Invalid remote-control option value.\n", .{});
            return @intFromEnum(schema.ExitCode.usage);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer parsed.deinit(alloc);

    const id_result = try runLaunchCompatStep(
        alloc,
        executable,
        invocation.options,
        password,
        "new-window",
        &.{},
        stderr,
    );
    const id_text = switch (id_result) {
        .ok => |stdout| stdout,
        .exit_code => |code| return code,
    };
    defer alloc.free(id_text);

    const id = std.fmt.parseUnsigned(u64, std.mem.trim(u8, id_text, " \r\n\t"), 10) catch {
        try stderr.print("Failed to parse the created window id.\n", .{});
        return @intFromEnum(schema.ExitCode.remote_failure);
    };

    const match_arg = try std.fmt.allocPrint(alloc, "id:{d}", .{id});
    defer alloc.free(match_arg);

    if (parsed.title) |title| {
        const title_args = [_][]const u8{ "--match", match_arg, title };
        switch (try runLaunchCompatStep(
            alloc,
            executable,
            invocation.options,
            password,
            "set-window-title",
            title_args[0..],
            stderr,
        )) {
            .ok => |stdout| alloc.free(stdout),
            .exit_code => |code| return code,
        }
    }

    const launch_text = try remote.launch.buildLaunchText(alloc, parsed);
    defer if (launch_text) |text| alloc.free(text);
    if (launch_text) |text| {
        const submit_text = std.mem.trimRight(u8, text, "\r");
        const text_args = [_][]const u8{ "--match", match_arg, submit_text };
        switch (try runLaunchCompatStep(
            alloc,
            executable,
            invocation.options,
            password,
            "send-line",
            text_args[0..],
            stderr,
        )) {
            .ok => |stdout| alloc.free(stdout),
            .exit_code => |code| return code,
        }
    }

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{d}\n", .{id});
    try stdout.flush();
    return @intFromEnum(schema.ExitCode.success);
}

fn runLaunchCompatStep(
    alloc: Allocator,
    executable: []const u8,
    options: Options,
    password: ?[]const u8,
    command_name: []const u8,
    command_args: []const []const u8,
    stderr: *std.Io.Writer,
) !LaunchCompatStepResult {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);

    try args.append(alloc, executable);
    try args.append(alloc, "@");
    try appendSharedLaunchOptions(alloc, &args, options, password);
    try args.append(alloc, command_name);
    try args.appendSlice(alloc, command_args);

    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    try env_map.put("JTERM_RC_NO_LAUNCH_COMPAT", "1");

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = args.items,
        .env_map = &env_map,
    });
    errdefer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return .{ .ok = result.stdout };
            if (result.stderr.len > 0) {
                try stderr.writeAll(result.stderr);
                if (result.stderr[result.stderr.len - 1] != '\n') try stderr.writeAll("\n");
            }
            alloc.free(result.stdout);
            return .{ .exit_code = @intCast(code) };
        },
        else => {
            if (result.stderr.len > 0) {
                try stderr.writeAll(result.stderr);
                if (result.stderr[result.stderr.len - 1] != '\n') try stderr.writeAll("\n");
            } else {
                try stderr.print("Remote-control subprocess terminated unexpectedly.\n", .{});
            }
            alloc.free(result.stdout);
            return .{ .exit_code = @intFromEnum(schema.ExitCode.transport) };
        },
    }
}

fn appendSharedLaunchOptions(
    alloc: Allocator,
    args: *std.ArrayList([]const u8),
    options: Options,
    password: ?[]const u8,
) !void {
    if (options.to) |value| {
        try args.append(alloc, "--to");
        try args.append(alloc, value);
    }
    if (password) |value| {
        try args.append(alloc, "--password");
        try args.append(alloc, value);
    }
    if (options.password_file) |value| {
        try args.append(alloc, "--password-file");
        try args.append(alloc, value);
    }
    if (options.password_env) |value| {
        try args.append(alloc, "--password-env");
        try args.append(alloc, value);
    }

    switch (options.use_password) {
        .if_available => {},
        .always => try args.append(alloc, "--use-password=always"),
        .never => try args.append(alloc, "--use-password=never"),
    }
}

fn detectExplicitHelpRequest(argv: []const []const u8) HelpRequest {
    const marker = findMarker(argv) orelse return .{ .explicit = false, .target = null };

    var options: Options = .{};
    var i: usize = marker + 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (parseGlobalOption(argv, &i, &options, arg, false) catch false) continue;
        if (std.mem.startsWith(u8, arg, "--")) return .{ .explicit = false, .target = null };
        if (std.mem.eql(u8, arg, "help")) {
            const next = i + 1;
            return .{
                .explicit = true,
                .target = if (next < argv.len) argv[next] else null,
            };
        }
        return .{ .explicit = false, .target = null };
    }

    return .{ .explicit = false, .target = null };
}

fn printDetectedHelp(command_name: ?[]const u8) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (command_name) |cmd| {
        try printCommandHelp(stdout, cmd);
    } else {
        try printGlobalHelp(stdout);
    }

    try stdout.flush();
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

fn canonicalizeInvocation(
    alloc: Allocator,
    invocation: *Invocation,
) !void {
    if (std.mem.eql(u8, invocation.command_name, "send-line")) {
        invocation.command_name = "send-text";
        if (invocation.options.submit == .none) {
            invocation.options.submit = .enter;
        }
        return;
    }

    if (launchCompatEnabled() and std.mem.eql(u8, invocation.command_name, "new-window")) {
        const rewritten = try canonicalizeNewWindowArgs(alloc, invocation.command_args);
        if (invocation._owned_command_args) |v| alloc.free(v);
        invocation.command_name = "launch";
        invocation.command_args = rewritten;
        invocation._owned_command_args = rewritten;
    }
}

fn launchCompatEnabled() bool {
    return std.posix.getenv("JTERM_RC_NO_LAUNCH_COMPAT") == null;
}

fn canonicalizeNewWindowArgs(
    alloc: Allocator,
    args: []const []const u8,
) ![]const []const u8 {
    var rewritten: std.ArrayList([]const u8) = .empty;
    defer rewritten.deinit(alloc);

    try rewritten.appendSlice(alloc, &.{ "--type", "os-window" });
    try rewritten.appendSlice(alloc, args);
    return try rewritten.toOwnedSlice(alloc);
}

fn validateInvocation(
    stderr: *std.Io.Writer,
    invocation: Invocation,
) schema.ValidationError!void {
    schema.validateCommandArgs(invocation.command_name, invocation.command_args) catch |err| {
        if (schema.renderCommandHelp(std.heap.page_allocator, invocation.command_name) catch null) |help| {
            defer std.heap.page_allocator.free(help);
            stderr.print("{s}\n", .{help}) catch {};
        }
        return err;
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

    if (std.mem.startsWith(u8, arg, "--submit=")) {
        options.submit = try parseSubmitMode(arg["--submit=".len..]);
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--match-tab=")) {
        options.match_tab = try requireValue(arg["--match-tab=".len..]);
        return true;
    }

    if (std.mem.eql(u8, arg, "--match") or
        std.mem.eql(u8, arg, "--match-tab") or
        std.mem.eql(u8, arg, "--response-timeout") or
        std.mem.eql(u8, arg, "--submit"))
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
        if (std.mem.eql(u8, arg, "--submit")) options.submit = try parseSubmitMode(value);
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

fn parseSubmitMode(value: []const u8) ParseError!Options.SubmitMode {
    return std.meta.stringToEnum(Options.SubmitMode, value) orelse error.InvalidValue;
}

fn submitToken(mode: Options.SubmitMode) ?[]const u8 {
    return switch (mode) {
        .none => null,
        .enter, .assistant => "enter",
    };
}

fn commandHelp(command_name: []const u8) ?CommandHelp {
    if (std.mem.eql(u8, command_name, "action")) {
        return .{
            .usage = "Usage: jterm @ action [options] <action-name>",
            .lines = &.{
                "Run a binding action on the target surface or app.",
                "",
                "Options:",
                "  --match <expr>",
                "  --self",
                "  --no-response",
                "",
                "Example:",
                "  jterm @ action --match \"id:12\" clear_screen",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "close-tab")) {
        return .{
            .usage = "Usage: jterm @ close-tab [options] [this|other|right]",
            .lines = &.{
                "Close tab(s) on the matched target.",
                "",
                "Options:",
                "  --match <expr>",
                "  --ignore-no-match",
                "  --no-response",
                "  --self",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "send-line")) {
        return .{
            .usage = "Usage: jterm @ send-line [routing options] <text>",
            .lines = &.{
                "Submit one line of text by sending text and then Enter.",
                "",
                "Recommended for shell commands and assistant TUIs such as Claude Code.",
                "",
                "Routing options:",
                "  --match <expr>",
                "  --match-tab <expr>",
                "  --all",
                "  --exclude-active",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "send-text")) {
        return .{
            .usage = "Usage: jterm @ send-text [routing options] [text options] <text>",
            .lines = &.{
                "Send text without synthesizing Enter unless --submit is set.",
                "",
                "Routing options:",
                "  --match <expr>",
                "  --match-tab <expr>",
                "  --all",
                "  --exclude-active",
                "",
                "Text options:",
                "  --stdin",
                "  --from-file <path>",
                "  --bracketed-paste disable|enable",
                "  --submit none|enter|assistant",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "send-key")) {
        return .{
            .usage = "Usage: jterm @ send-key [routing options] <key> [key ...]",
            .lines = &.{
                "Send one or more literal key presses such as enter, escape, or ctrl+c.",
                "",
                "Routing options:",
                "  --match <expr>",
                "  --match-tab <expr>",
                "  --all",
                "  --exclude-active",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "launch")) {
        return .{
            .usage = "Usage: jterm @ launch [launch options] [command ...]",
            .lines = &.{
                "Canonical way to open a new terminal window and optionally run setup text or a command.",
                "",
                "Launch options:",
                "  --type os-window|window",
                "  --title <text>",
                "  --cwd <path>",
                "  --env KEY=VALUE",
                "  --os-window-state normal|maximized|minimized|hidden",
                "",
                "Examples:",
                "  jterm @ launch --type os-window --title \"Claude Chat\"",
                "  jterm @ launch --type os-window --title \"Claude Chat\" --cwd ~/code/misc",
                "  jterm @ launch --type os-window --cwd ~/code/misc -- claude",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "new-window")) {
        return .{
            .usage = "Usage: jterm @ new-window [window options]",
            .lines = &.{
                "Convenience alias for `launch --type os-window`.",
                "",
                "Window options:",
                "  --title <text>",
                "  --cwd <path>",
                "  --env KEY=VALUE",
                "  --os-window-state normal|maximized|minimized|hidden",
                "",
                "Example:",
                "  jterm @ new-window --title \"Claude Chat\" --cwd ~/code/misc",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "new-tab")) {
        return .{
            .usage = "Usage: jterm @ new-tab",
            .lines = &.{
                "Create a new tab in the focused window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "create-marker")) {
        return .{
            .usage = "Usage: jterm @ create-marker --match <expr> <marker>",
            .lines = &.{
                "Create a marker such as `prompt` on the target window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "remove-marker")) {
        return .{
            .usage = "Usage: jterm @ remove-marker --match <expr> <marker>",
            .lines = &.{
                "Remove a marker such as `prompt` from the target window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "detach-tab")) {
        return .{
            .usage = "Usage: jterm @ detach-tab [options]",
            .lines = &.{
                "Detach the matched tab into its own OS window.",
                "",
                "Options:",
                "  --match <expr>",
                "  --target-tab <expr>",
                "  --self",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "detach-window")) {
        return .{
            .usage = "Usage: jterm @ detach-window [options]",
            .lines = &.{
                "Detach the matched split/window from its current tab.",
                "",
                "Options:",
                "  --match <expr>",
                "  --target-tab <expr>",
                "  --self",
                "  --stay-in-tab",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "disable-ligatures")) {
        return .{
            .usage = "Usage: jterm @ disable-ligatures [options] <always|never|cursor>",
            .lines = &.{
                "Toggle ligature rendering policy on matching windows.",
                "",
                "Options:",
                "  --all",
                "  --match <expr>",
                "  --match-tab <expr>",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "env")) {
        return .{
            .usage = "Usage: jterm @ env --match <expr> KEY=VALUE [KEY=VALUE ...]",
            .lines = &.{
                "Set or update environment metadata tags used for later matching.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "focus-tab")) {
        return .{
            .usage = "Usage: jterm @ focus-tab --match <expr>",
            .lines = &.{
                "Focus the first matching tab.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "ls")) {
        return .{
            .usage = "Usage: jterm @ ls",
            .lines = &.{
                "List live windows and tabs as JSON.",
                "",
                "Options:",
                "  --match <expr>",
                "  --match-tab <expr>",
                "  --all-env-vars",
                "  --self",
                "  --output-format json",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "get-text")) {
        return .{
            .usage = "Usage: jterm @ get-text [options]",
            .lines = &.{
                "Read text from a target window.",
                "",
                "Options:",
                "  --match <expr>",
                "  --extent screen|all|selection|first_cmd_output_on_screen|last_cmd_output|last_visited_cmd_output|last_non_empty_output",
                "  --ansi",
                "  --add-cursor",
                "  --add-wrap-markers",
                "  --clear-selection",
                "  --self",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "get-colors")) {
        return .{
            .usage = "Usage: jterm @ get-colors [options]",
            .lines = &.{
                "Print colors for the matching window.",
                "",
                "Options:",
                "  --match <expr>",
                "  --configured",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "goto-layout")) {
        return .{
            .usage = "Usage: jterm @ goto-layout --match <expr> <layout>",
            .lines = &.{
                "Change the target window layout, for example `stack` or `splits`.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "kitten")) {
        return .{
            .usage = "Usage: jterm @ kitten --match <expr> <kitten-name> [args...]",
            .lines = &.{
                "Run a kitten-style helper command on the target window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "last-used-layout")) {
        return .{
            .usage = "Usage: jterm @ last-used-layout [options]",
            .lines = &.{
                "Restore the previous layout on matching windows.",
                "",
                "Options:",
                "  --all",
                "  --match <expr>",
                "  --no-response",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "scroll-window")) {
        return .{
            .usage = "Usage: jterm @ scroll-window [options] <amount|start|end>",
            .lines = &.{
                "Scroll a window by line count or jump to start/end.",
                "",
                "Options:",
                "  --match <expr>",
                "  --no-response",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "select-window")) {
        return .{
            .usage = "Usage: jterm @ select-window [options]",
            .lines = &.{
                "Interactive focus flow. If only one target matches, it focuses immediately.",
                "",
                "Options:",
                "  --match <expr>",
                "  --response-timeout <seconds>",
                "  --self",
                "  --title <text>",
                "  --exclude-active",
                "  --reactivate-prev-tab",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "focus-window")) {
        return .{
            .usage = "Usage: jterm @ focus-window --match <expr>",
            .lines = &.{
                "Focus the first matching window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "close-window")) {
        return .{
            .usage = "Usage: jterm @ close-window --match <expr>",
            .lines = &.{
                "Close matching windows.",
                "",
                "Options:",
                "  --match <expr>",
                "  --ignore-no-match",
                "  --no-response",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "move-os-window")) {
        return .{
            .usage = "Usage: jterm @ move-os-window --match <expr> --monitor <n|mN|current>",
            .lines = &.{
                "Move the matched OS window to a monitor.",
                "",
                "Monitor values:",
                "  4",
                "  m4",
                "  current | active | this",
                "",
                "Examples:",
                "  jterm @ move-os-window --match \"id:5\" --monitor 4",
                "  jterm @ move-os-window --match \"id:5\" --monitor m2",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "maximize-os-window")) {
        return .{
            .usage = "Usage: jterm @ maximize-os-window --match <expr> [--monitor <n|mN|current>]",
            .lines = &.{
                "Maximize the OS window, optionally on a specific monitor.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "minimize-os-window")) {
        return .{
            .usage = "Usage: jterm @ minimize-os-window --match <expr> [--monitor <n|mN|current>]",
            .lines = &.{
                "Minimize the matched OS window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "hide-os-window")) {
        return .{
            .usage = "Usage: jterm @ hide-os-window --match <expr> [--monitor <n|mN|current>]",
            .lines = &.{
                "Hide the matched OS window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "snap-os-window")) {
        return .{
            .usage = "Usage: jterm @ snap-os-window --match <expr> <left|right|quadrant1|quadrant2|quadrant3|quadrant4> [--monitor <n|mN|current>]",
            .lines = &.{
                "Snap the OS window to a side or quadrant on a monitor.",
                "",
                "Quadrant aliases:",
                "  q1|top-left   q2|top-right",
                "  q3|bottom-left q4|bottom-right",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "resize-os-window")) {
        return .{
            .usage = "Usage: jterm @ resize-os-window --match <expr> <WIDTHxHEIGHT | --width N --height N>",
            .lines = &.{
                "Resize the host OS window using cell dimensions.",
                "",
                "Examples:",
                "  jterm @ resize-os-window --match \"id:5\" 120x40",
                "  jterm @ resize-os-window --match \"id:5\" --width 120 --height 40",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "resize-window")) {
        return .{
            .usage = "Usage: jterm @ resize-window --match <expr> <wider|narrower|taller|shorter|reset> [amount]",
            .lines = &.{
                "Resize a split/terminal pane inside the window.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "run")) {
        return .{
            .usage = "Usage: jterm @ run [options] <command> [args...]",
            .lines = &.{
                "Run a command and return its stdout.",
                "",
                "Options:",
                "  --env KEY=VALUE",
                "  --allow-remote-control",
                "  --remote-control-password <password>",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-window-title")) {
        return .{
            .usage = "Usage: jterm @ set-window-title [options] <title>",
            .lines = &.{
                "Set the title of the matching window.",
                "",
                "Options:",
                "  --match <expr>",
                "  --temporary",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-tab-title")) {
        return .{
            .usage = "Usage: jterm @ set-tab-title [options] <title>",
            .lines = &.{
                "Set the title of the matching tab.",
                "",
                "Options:",
                "  --match <expr>",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-background-image")) {
        return .{
            .usage = "Usage: jterm @ set-background-image [options] <path>",
            .lines = &.{
                "Set a background image on matching windows.",
                "",
                "Options:",
                "  --all",
                "  --configured",
                "  --layout configured|tiled|centered|scaled",
                "  --match <expr>",
                "  --no-response",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-background-opacity")) {
        return .{
            .usage = "Usage: jterm @ set-background-opacity [options] <opacity>",
            .lines = &.{
                "Set or toggle background opacity.",
                "",
                "Options:",
                "  --all",
                "  --toggle",
                "  --match <expr>",
                "  --match-tab <expr>",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-colors")) {
        return .{
            .usage = "Usage: jterm @ set-colors [options] KEY=VALUE [KEY=VALUE ...]",
            .lines = &.{
                "Apply color overrides such as `foreground=#ffffff`.",
                "",
                "Options:",
                "  --all",
                "  --configured",
                "  --reset",
                "  --match <expr>",
                "  --match-tab <expr>",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-enabled-layouts")) {
        return .{
            .usage = "Usage: jterm @ set-enabled-layouts [options] <layout1,layout2,...>",
            .lines = &.{
                "Set the enabled layouts list on matching windows.",
                "",
                "Options:",
                "  --match <expr>",
                "  --configured",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-font-size")) {
        return .{
            .usage = "Usage: jterm @ set-font-size [options] <points>",
            .lines = &.{
                "Set the font size override.",
                "",
                "Options:",
                "  --all",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-spacing")) {
        return .{
            .usage = "Usage: jterm @ set-spacing [options] <key=value> [key=value ...]",
            .lines = &.{
                "Set spacing/padding overrides such as `padding=10`.",
                "",
                "Options:",
                "  --all",
                "  --configured",
                "  --match <expr>",
                "  --match-tab <expr>",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-tab-color")) {
        return .{
            .usage = "Usage: jterm @ set-tab-color [options] <color-or-key=value> [more...]",
            .lines = &.{
                "Set tab colors on the matched tab.",
                "",
                "Options:",
                "  --match <expr>",
                "  --self",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-user-vars")) {
        return .{
            .usage = "Usage: jterm @ set-user-vars --match <expr> KEY=VALUE [KEY=VALUE ...]",
            .lines = &.{
                "Set user variables for later matching or metadata.",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "set-window-logo")) {
        return .{
            .usage = "Usage: jterm @ set-window-logo [options] <path>",
            .lines = &.{
                "Set a window logo image.",
                "",
                "Options:",
                "  --match <expr>",
                "  --self",
                "  --position <corner>",
                "  --alpha <0..1>",
                "  --no-response",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "signal-child")) {
        return .{
            .usage = "Usage: jterm @ signal-child --match <expr> <signal>",
            .lines = &.{
                "Send a signal such as `SIGTERM` to the child process of the target window.",
                "",
                "Options:",
                "  --match <expr>",
                "  --no-response",
            },
        };
    }

    if (std.mem.eql(u8, command_name, "load-config")) {
        return .{
            .usage = "Usage: jterm @ load-config",
            .lines = &.{
                "Reload the active jTerm config file.",
                "",
                "Options:",
                "  --ignore-overrides",
                "  --override <key=value>",
                "  --no-response",
            },
        };
    }

    return null;
}

fn commandSummary(command_name: []const u8) ?[]const u8 {
    const spec = schema.specForName(command_name) orelse return null;
    return spec.summary;
}

fn sendRemoteCommand(
    alloc: Allocator,
    stderr: *std.Io.Writer,
    target: []const u8,
    options: Options,
    password: ?[]const u8,
    command_name: []const u8,
    command_args: []const []const u8,
) !void {
    const no_response = computeNoResponse(options, command_name, defaultNoResponse(alloc));
    const use_password_transport = options.use_password != .never and
        password != null and
        password.?.len > 0;
    const timestamp_ns: ?i64 = if (use_password_transport) @intCast(std.time.nanoTimestamp()) else null;

    const request = try remote.protocol.encodeRequest(
        alloc,
        .{
            .cmd = command_name,
            .argv = command_args,
            .match = options.match,
            .match_tab = options.match_tab,
            .all = options.all,
            .ignore_no_match = options.ignore_no_match,
            .no_response = no_response,
            .password = password,
            .timestamp = timestamp_ns,
            .response_timeout = options.response_timeout,
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
            return error.InvalidValue;
        };

        const parsed_key = remote.protocol.decodeKittyPublicKey(alloc, encoded_key) catch {
            try stderr.print("Invalid KITTY_PUBLIC_KEY value.\n", .{});
            return error.InvalidValue;
        };
        encrypted_request = remote.protocol.encryptRequestForServer(alloc, request, parsed_key.public_key) catch {
            try stderr.print("Failed to encrypt password-authenticated request.\n", .{});
            return error.InvalidValue;
        };
        break :payload encrypted_request.?;
    };

    const response = remote.transport.request(alloc, target, request_payload) catch |err| switch (err) {
        error.InvalidTarget => {
            try stderr.print("`--to` must use unix socket format `unix:/path`.\n", .{});
            return error.InvalidValue;
        },
        error.EmptyResponse => {
            if (no_response) return;
            try stderr.print("Remote-control server returned an empty response.\n", .{});
            return error.InvalidValue;
        },
        error.ResponseTooLarge => {
            try stderr.print("Remote-control response exceeded maximum allowed size.\n", .{});
            return error.InvalidValue;
        },
        else => {
            try stderr.print("Remote-control transport failure: {}\n", .{err});
            return error.InvalidValue;
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
                    return error.InvalidValue;
                }
            }
        }
    }
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
    return schema.commandForcesResponse(command_name);
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
    switch (schema.outputKindForCommand(command_name)) {
        .none => {},
        .json => {
            const out = try std.json.Stringify.valueAlloc(alloc, data, .{});
            defer alloc.free(out);
            try stdout.print("{s}\n", .{out});
        },
        .id => {
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
        },
        .run_stdout => {
            if (data == .object) {
                const data_obj = data.object;
                if (data_obj.get("stdout")) |stdout_value| {
                    if (stdout_value == .string and stdout_value.string.len > 0) {
                        try stdout.writeAll(stdout_value.string);
                    }
                }
            }
        },
        .focused_flag => {
            if (data == .object) {
                const data_obj = data.object;
                if (data_obj.get("focused")) |focused| {
                    if (focused == .bool and focused.bool) {
                        try stdout.writeAll("1\n");
                    }
                }
            }
        },
        .text => {
            if (data == .object) {
                const data_obj = data.object;
                if (data_obj.get("text")) |text_value| {
                    if (text_value == .string and text_value.string.len > 0) {
                        try stdout.writeAll(text_value.string);
                    }
                }
            }
        },
        .colors => {
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
        },
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
    const text = try schema.renderGlobalHelp(std.heap.page_allocator);
    defer std.heap.page_allocator.free(text);
    try stdout.writeAll(text);
}

fn printCommandHelp(stdout: *std.Io.Writer, command_name: []const u8) !void {
    if (try schema.renderCommandHelp(std.heap.page_allocator, command_name)) |text| {
        defer std.heap.page_allocator.free(text);
        try stdout.writeAll(text);
        return;
    }

    try stdout.print("Usage: jterm @ {s} [options]\n\n", .{command_name});
    try stdout.writeAll("Use `jterm @ help` docs or the skill reference for this command.\n");
}

fn classifyRemoteFailure(message: []const u8) u8 {
    if (std.mem.indexOf(u8, message, "no match") != null or
        std.mem.indexOf(u8, message, "No match") != null or
        std.mem.indexOf(u8, message, "not found") != null)
    {
        return @intFromEnum(schema.ExitCode.target);
    }
    if (std.mem.indexOf(u8, message, "unsupported") != null or
        std.mem.indexOf(u8, message, "not supported") != null)
    {
        return @intFromEnum(schema.ExitCode.unsupported);
    }
    if (std.mem.indexOf(u8, message, "authorization") != null or
        std.mem.indexOf(u8, message, "password") != null)
    {
        return @intFromEnum(schema.ExitCode.transport);
    }
    return @intFromEnum(schema.ExitCode.remote_failure);
}

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

test "parseInvocation parses send-text submit mode" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "send-text",
        "--submit=assistant",
        "hello",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try testing.expectEqual(Options.SubmitMode.assistant, invocation.options.submit);
}

test "detectExplicitHelpRequest finds command help target" {
    const testing = std.testing;

    const request = detectExplicitHelpRequest(&.{
        "jterm",
        "@",
        "help",
        "move-os-window",
    });

    try testing.expect(request.explicit);
    try testing.expectEqualStrings("move-os-window", request.target.?);
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

test "default remote-control target is build specific" {
    const testing = std.testing;

    if (@import("builtin").mode == .Debug) {
        try testing.expectEqualStrings("unix:/tmp/jterm-dev.sock", build_config.default_remote_control_target);
    } else {
        try testing.expectEqualStrings("unix:/tmp/jterm-stable.sock", build_config.default_remote_control_target);
    }
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

test "parseInvocation rejects command options before command" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "--response",
        "--match=recent:0",
        "ls",
    };

    try testing.expectError(error.UnknownOption, parseInvocation(testing.allocator, argv[0..]));
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

test "canonicalizeInvocation rewrites new-window as launch" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "new-window",
        "--title",
        "Claude Chat",
        "--cwd",
        "~/code/misc",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try canonicalizeInvocation(testing.allocator, &invocation);

    try testing.expectEqualStrings("launch", invocation.command_name);
    try testing.expectEqual(@as(usize, 6), invocation.command_args.len);
    try testing.expectEqualStrings("--type", invocation.command_args[0]);
    try testing.expectEqualStrings("os-window", invocation.command_args[1]);
    try testing.expectEqualStrings("--title", invocation.command_args[2]);
    try testing.expectEqualStrings("Claude Chat", invocation.command_args[3]);
    try testing.expectEqualStrings("--cwd", invocation.command_args[4]);
    try testing.expectEqualStrings("~/code/misc", invocation.command_args[5]);
}

test "canonicalizeInvocation rewrites send-line as send-text submit enter" {
    const testing = std.testing;

    const argv = [_][]const u8{
        "jterm",
        "@",
        "send-line",
        "hello",
    };

    var invocation = try parseInvocation(testing.allocator, argv[0..]);
    defer invocation.deinit(testing.allocator);
    try canonicalizeInvocation(testing.allocator, &invocation);

    try testing.expectEqualStrings("send-text", invocation.command_name);
    try testing.expectEqual(Options.SubmitMode.enter, invocation.options.submit);
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
    try testing.expectEqual(expected.submit, actual.submit);
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

test "parseInvocation parses every command option form after command" {
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

test "parseInvocation supports all commands with global options before command" {
    const testing = std.testing;

    const pre_command = [_][]const u8{
        "--to=unix:/tmp/jterm-custom.sock",
        "--password=top-secret",
        "--password-file=/tmp/jterm-pass.txt",
        "--password-env=JTERM_PASS",
        "--use-password=always",
    };

    const expected: Options = .{
        .to = "unix:/tmp/jterm-custom.sock",
        .password = "top-secret",
        .password_file = "/tmp/jterm-pass.txt",
        .password_env = "JTERM_PASS",
        .use_password = .always,
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
        .{ .argv = &.{ "jterm", "@", "--match" }, .expected = error.UnknownOption },
        .{ .argv = &.{ "jterm", "@", "--match-tab" }, .expected = error.UnknownOption },
        .{ .argv = &.{ "jterm", "@", "--response-timeout" }, .expected = error.UnknownOption },
        .{ .argv = &.{ "jterm", "@", "--to=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password-file=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--password-env=" }, .expected = error.MissingValue },
        .{ .argv = &.{ "jterm", "@", "--use-password=" }, .expected = error.InvalidValue },
        .{ .argv = &.{ "jterm", "@", "--match=" }, .expected = error.UnknownOption },
        .{ .argv = &.{ "jterm", "@", "--match-tab=" }, .expected = error.UnknownOption },
        .{ .argv = &.{ "jterm", "@", "--response-timeout=" }, .expected = error.UnknownOption },
    };

    for (cases) |case| {
        try testing.expectError(case.expected, parseInvocation(testing.allocator, case.argv));
    }
}

test "parseInvocation rejects invalid response-timeout values in all forms" {
    const testing = std.testing;

    const Case = struct {
        argv: []const []const u8,
        expected: anyerror,
    };

    const cases = [_]Case{
        .{ .argv = &.{ "jterm", "@", "--response-timeout=abc", "ls" }, .expected = error.UnknownOption },
        .{ .argv = &.{ "jterm", "@", "--response-timeout", "abc", "ls" }, .expected = error.UnknownOption },
        .{ .argv = &.{ "jterm", "@", "ls", "--response-timeout=abc" }, .expected = error.InvalidValue },
        .{ .argv = &.{ "jterm", "@", "ls", "--response-timeout", "abc" }, .expected = error.InvalidValue },
    };

    for (cases) |case| {
        try testing.expectError(case.expected, parseInvocation(testing.allocator, case.argv));
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

test "printCommandHelp for send-text is command specific" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try printCommandHelp(&out.writer, "send-text");
    const text = try out.toOwnedSlice();
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "--submit none|enter|assistant") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--cwd") == null);
}

test "printGlobalHelp lists every command name" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try printGlobalHelp(&out.writer);
    const text = try out.toOwnedSlice();
    defer testing.allocator.free(text);

    for (remote.command.all) |cmd| {
        const needle = try std.fmt.allocPrint(testing.allocator, "{s}", .{remote.command.name(cmd)});
        defer testing.allocator.free(needle);
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}

test "every remote command has schema-backed help" {
    const testing = std.testing;

    for (remote.command.all) |cmd| {
        const name = remote.command.name(cmd);
        try testing.expect(commandHelp(name) != null);
        try testing.expect(commandSummary(name) != null);
    }
}

test "printCommandHelp never falls back for remote commands" {
    const testing = std.testing;

    for (remote.command.all) |cmd| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();

        try printCommandHelp(&out.writer, remote.command.name(cmd));
        const text = try out.toOwnedSlice();
        defer testing.allocator.free(text);

        try testing.expect(std.mem.indexOf(u8, text, "Use `jterm @ help` docs or the skill reference for this command.") == null);
    }
}

test "printCommandHelp for new-window shows intuitive sugar" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try printCommandHelp(&out.writer, "new-window");
    const text = try out.toOwnedSlice();
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Supported sugar over `launch --type os-window`.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--title") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--cwd") != null);
}

test "printCommandHelp for move-os-window mentions monitor targeting" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try printCommandHelp(&out.writer, "move-os-window");
    const text = try out.toOwnedSlice();
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "--monitor <n|mN|current>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "jterm @ move-os-window --match \"id:5\" --monitor 4") != null);
}

test "printGlobalHelp includes send-line" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try printGlobalHelp(&out.writer);
    const text = try out.toOwnedSlice();
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "send-line") != null);
}
