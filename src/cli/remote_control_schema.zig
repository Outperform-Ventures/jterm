const std = @import("std");
const Allocator = std.mem.Allocator;
const remote = @import("../remote/main.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    target = 3,
    transport = 4,
    remote_failure = 5,
    unsupported = 6,
};

pub const OutputKind = enum {
    none,
    id,
    json,
    text,
    colors,
    run_stdout,
    focused_flag,
};

pub const ResponseBehavior = enum {
    config_driven,
    force_response,
};

pub const OptionValue = enum {
    none,
    required,
};

pub const PositionalPolicy = struct {
    min: usize = 0,
    max: ?usize = 0,
    summary: []const u8 = "",
};

pub const OptionSpec = struct {
    forms: []const []const u8,
    value_name: ?[]const u8 = null,
    value_kind: OptionValue = .none,
    repeatable: bool = false,
    description: []const u8,
};

pub const Section = struct {
    title: []const u8,
    lines: []const []const u8,
};

pub const CommandSpec = struct {
    key: ?remote.command.Key,
    name: []const u8,
    summary: []const u8,
    synopsis: []const u8,
    description: []const []const u8,
    positional: PositionalPolicy = .{},
    options: []const OptionSpec = &.{},
    matching: []const []const u8 = &.{},
    output: []const []const u8,
    notes: []const []const u8 = &.{},
    platform_notes: []const []const u8 = &.{},
    examples: []const []const u8 = &.{},
    output_kind: OutputKind = .none,
    response_behavior: ResponseBehavior = .config_driven,
    alias_of: ?[]const u8 = null,
    validator: ?*const fn ([]const []const u8) ValidationError!void = null,
};

pub const ValidationError = error{
    MissingValue,
    UnknownOption,
    InvalidValue,
    MissingArgument,
    TooManyArguments,
};

const matching_lines = [_][]const u8{
    "Use --match and --match-tab to select targets. Canonical follow-up workflows should use id:<n>.",
    "Matching expressions support id, pid, num, title, cwd, cmdline, session, state, recent, env, and var keys.",
    "`,` means AND and `||` means OR.",
};

const exit_status_lines = [_][]const u8{
    "0  success",
    "2  usage or validation error",
    "3  target selection failure",
    "4  transport or authentication failure",
    "5  remote action failure",
    "6  unsupported capability or platform constraint",
};

pub const global_options = [_]OptionSpec{
    .{
        .forms = &.{"--to"},
        .value_name = "unix:/path.sock",
        .value_kind = .required,
        .description = "Override the remote-control socket target.",
    },
    .{
        .forms = &.{"--password"},
        .value_name = "token",
        .value_kind = .required,
        .description = "Provide the remote-control password directly.",
    },
    .{
        .forms = &.{"--password-file"},
        .value_name = "path",
        .value_kind = .required,
        .description = "Read the remote-control password from a file.",
    },
    .{
        .forms = &.{"--password-env"},
        .value_name = "ENV_NAME",
        .value_kind = .required,
        .description = "Read the remote-control password from an environment variable.",
    },
    .{
        .forms = &.{"--use-password"},
        .value_name = "if-available|always|never",
        .value_kind = .required,
        .description = "Control whether password transport is used.",
    },
    .{
        .forms = &.{ "--help", "-h" },
        .description = "Show global help or command-specific help.",
    },
};

const route_match = OptionSpec{
    .forms = &.{ "--match", "-m" },
    .value_name = "expr",
    .value_kind = .required,
    .description = "Target windows or surfaces matching the expression.",
};
const route_match_tab = OptionSpec{
    .forms = &.{ "--match-tab", "-t" },
    .value_name = "expr",
    .value_kind = .required,
    .description = "Target tabs matching the expression.",
};
const route_all = OptionSpec{
    .forms = &.{ "--all", "-a" },
    .description = "Apply the command to every matching target.",
};
const route_ignore_no_match = OptionSpec{
    .forms = &.{"--ignore-no-match"},
    .description = "Exit successfully when no targets match.",
};
const route_no_response = OptionSpec{
    .forms = &.{"--no-response"},
    .description = "Suppress the response body for this invocation.",
};
const route_response = OptionSpec{
    .forms = &.{"--response"},
    .description = "Force printing a response body for this invocation.",
};
const route_response_timeout = OptionSpec{
    .forms = &.{"--response-timeout"},
    .value_name = "seconds",
    .value_kind = .required,
    .description = "Set a response timeout hint for interactive commands.",
};
const route_self = OptionSpec{
    .forms = &.{"--self"},
    .description = "Scope the command to the current terminal context when supported.",
};

pub fn specForName(name: []const u8) ?*const CommandSpec {
    inline for (&specs) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub fn specForKey(key: remote.command.Key) *const CommandSpec {
    inline for (&specs) |*spec| {
        if (spec.key != null and spec.key.? == key) return spec;
    }
    unreachable;
}

pub fn commandNamesWithAliases() []const []const u8 {
    return command_names_with_aliases[0..];
}

pub fn commandForcesResponse(name: []const u8) bool {
    const spec = specForName(name) orelse return false;
    return spec.response_behavior == .force_response;
}

pub fn outputKindForCommand(name: []const u8) OutputKind {
    const spec = specForName(name) orelse return .none;
    return spec.output_kind;
}

pub fn validateCommandArgs(command_name: []const u8, args: []const []const u8) ValidationError!void {
    const spec = specForName(command_name) orelse return;
    if (spec.validator) |validator| return validator(args);
    try validateBySpec(spec, args);
}

pub fn renderGlobalHelp(alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc,
        \\Usage: jterm @ [global options] <command> [command options] [command args]
        \\
        \\Control a running jTerm instance through the remote-control socket.
        \\Remote control requires `allow-remote-control = true` in config.
        \\
        \\Commands:
        \\
    );

    inline for (specs) |spec| {
        if (spec.key == null) continue;
        try out.writer(alloc).print("  {s:<22} {s}\n", .{ spec.name, spec.summary });
    }
    try out.writer(alloc).print("  {s:<22} {s}\n", .{ "send-line", send_line_spec.summary });

    try out.appendSlice(alloc,
        \\
        \\Global options:
        \\
    );
    for (global_options) |option| {
        try renderOptionLine(alloc, &out, option);
    }

    try out.appendSlice(alloc,
        \\
        \\Get command help with:
        \\  jterm @ <command> --help
        \\  jterm @ help <command>
        \\
    );

    return try out.toOwnedSlice(alloc);
}

pub fn renderCommandHelp(alloc: Allocator, command_name: []const u8) !?[]u8 {
    const spec = specForName(command_name) orelse return null;
    return try renderSingleCommandHelp(alloc, spec);
}

pub fn renderReferenceDoc(alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc,
        \\# jTerm Remote Control Reference
        \\
        \\This document is generated from `src/cli/remote_control_schema.zig`.
        \\Do not hand-edit command syntax here; update the schema instead.
        \\
        \\## Canonical Agent Workflow
        \\
        \\1. Create or discover the target window.
        \\2. Capture its unique id.
        \\3. Use only `id:<n>` for follow-up commands.
        \\4. Use `send-line` when the intent is to submit text.
        \\5. Use `get-text --extent screen` to verify results.
        \\
        \\Example:
        \\
        \\```bash
        \\window_id="$(jterm @ launch --type os-window --title "Claude Chat" --cwd ~/code/misc)"
        \\jterm @ send-line --match "id:$window_id" "claude"
        \\jterm @ send-line --match "id:$window_id" "Who was the 34th president?"
        \\jterm @ get-text --match "id:$window_id" --extent screen
        \\```
        \\
        \\## Global Options
        \\
    );

    for (global_options) |option| {
        try renderReferenceOption(alloc, &out, option);
    }

    try out.appendSlice(alloc,
        \\
        \\## Exit Status
        \\
    );
    for (exit_status_lines) |line| {
        try out.writer(alloc).print("- `{s}`\n", .{line});
    }

    try out.appendSlice(alloc,
        \\
        \\## Commands
        \\
    );

    inline for (specs) |spec| {
        if (spec.key == null) continue;
        try renderReferenceCommand(alloc, &out, spec);
    }
    try renderReferenceCommand(alloc, &out, send_line_spec);

    return try out.toOwnedSlice(alloc);
}

pub fn renderManpageDoc(alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc,
        \\# JTERM-RC(1)
        \\
        \\## NAME
        \\
        \\jterm @ - control a running jTerm instance over the remote-control socket
        \\
        \\## SYNOPSIS
        \\
        \\`jterm @ [global options] <command> [command options] [command args]`
        \\
        \\## DESCRIPTION
        \\
        \\The `jterm @` command sends kitty-compatible remote-control requests to a running jTerm app.
        \\The canonical automation workflow is: create or discover a window, capture its id, then use
        \\`id:<n>` matching for all follow-up operations. Use `send-line` when the intent is to submit text.
        \\
        \\## GLOBAL OPTIONS
        \\
    );

    for (global_options) |option| {
        try renderReferenceOption(alloc, &out, option);
    }

    try out.appendSlice(alloc,
        \\
        \\## EXIT STATUS
        \\
    );
    for (exit_status_lines) |line| {
        try out.writer(alloc).print("- `{s}`\n", .{line});
    }

    try out.appendSlice(alloc,
        \\
        \\## COMMANDS
        \\
    );

    inline for (specs) |spec| {
        if (spec.key == null) continue;
        try renderReferenceCommand(alloc, &out, spec);
    }
    try renderReferenceCommand(alloc, &out, send_line_spec);

    try out.appendSlice(alloc,
        \\
        \\## SEE ALSO
        \\
        \\- `docs/JTERM_REMOTE_CONTROL_USER_GUIDE.md`
        \\- `docs/REMOTE_CONTROL_MANPAGE_GRADE_PLAN.md`
        \\
    );

    return try out.toOwnedSlice(alloc);
}

fn validateBySpec(spec: *const CommandSpec, args: []const []const u8) ValidationError!void {
    var positional_count: usize = 0;
    var i: usize = 0;
    var parse_options = true;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (parse_options and std.mem.eql(u8, arg, "--")) {
            parse_options = false;
            continue;
        }

        if (parse_options and std.mem.startsWith(u8, arg, "-")) {
            const option = findOption(spec.options, arg) orelse return error.UnknownOption;
            if (option.value_kind == .required) {
                if (std.mem.indexOfScalar(u8, arg, '=')) |_| {
                    continue;
                }
                const next = i + 1;
                if (next >= args.len) return error.MissingValue;
                i = next;
                continue;
            }
            continue;
        }

        positional_count += 1;
    }

    if (positional_count < spec.positional.min) return error.MissingArgument;
    if (spec.positional.max) |max| {
        if (positional_count > max) return error.TooManyArguments;
    }
}

fn findOption(options: []const OptionSpec, token: []const u8) ?OptionSpec {
    for (options) |option| {
        for (option.forms) |form| {
            if (std.mem.eql(u8, token, form)) return option;
            if (option.value_kind == .required and std.mem.startsWith(u8, token, form)) {
                if (token.len > form.len and token[form.len] == '=') return option;
            }
        }
    }
    return null;
}

fn renderSingleCommandHelp(alloc: Allocator, spec: *const CommandSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.writer(alloc).print("NAME\n  {s} - {s}\n\n", .{ spec.name, spec.summary });
    try out.writer(alloc).print("SYNOPSIS\n  {s}\n\n", .{spec.synopsis});
    try renderSection(alloc, &out, "DESCRIPTION", spec.description);
    if (spec.positional.summary.len > 0) {
        try renderSection(alloc, &out, "ARGUMENTS", &.{spec.positional.summary});
    }
    if (spec.options.len > 0) {
        try out.appendSlice(alloc, "OPTIONS\n");
        for (spec.options) |option| {
            try renderOptionLine(alloc, &out, option);
        }
        try out.append(alloc, '\n');
    }
    if (spec.matching.len > 0) try renderSection(alloc, &out, "MATCHING", spec.matching);
    try renderSection(alloc, &out, "OUTPUT", spec.output);
    try renderSection(alloc, &out, "EXIT STATUS", exit_status_lines[0..]);
    if (spec.examples.len > 0) try renderSection(alloc, &out, "EXAMPLES", spec.examples);
    if (spec.notes.len > 0) try renderSection(alloc, &out, "NOTES", spec.notes);
    if (spec.platform_notes.len > 0) try renderSection(alloc, &out, "PLATFORM NOTES", spec.platform_notes);

    return try out.toOwnedSlice(alloc);
}

fn renderSection(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    title: []const u8,
    lines: []const []const u8,
) !void {
    if (lines.len == 0) return;
    try out.writer(alloc).print("{s}\n", .{title});
    for (lines) |line| {
        if (line.len == 0) {
            try out.append(alloc, '\n');
        } else {
            try out.writer(alloc).print("  {s}\n", .{line});
        }
    }
    try out.append(alloc, '\n');
}

fn renderOptionLine(alloc: Allocator, out: *std.ArrayList(u8), option: OptionSpec) !void {
    var first = true;
    try out.appendSlice(alloc, "  ");
    for (option.forms) |form| {
        if (!first) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, form);
        if (option.value_name) |value_name| {
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, value_name);
        }
        first = false;
    }
    try out.writer(alloc).print("\n      {s}\n", .{option.description});
}

fn renderReferenceOption(alloc: Allocator, out: *std.ArrayList(u8), option: OptionSpec) !void {
    try out.appendSlice(alloc, "- `");
    for (option.forms, 0..) |form, i| {
        if (i > 0) try out.appendSlice(alloc, "`, `");
        try out.appendSlice(alloc, form);
        if (option.value_name) |value_name| {
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, value_name);
        }
    }
    try out.writer(alloc).print("` — {s}\n", .{option.description});
}

fn renderReferenceCommand(alloc: Allocator, out: *std.ArrayList(u8), spec: CommandSpec) !void {
    try out.writer(alloc).print("### `{s}`\n\n", .{spec.name});
    try out.writer(alloc).print("- Summary: {s}\n", .{spec.summary});
    try out.writer(alloc).print("- Synopsis: `{s}`\n", .{spec.synopsis});
    if (spec.alias_of) |alias_of| {
        try out.writer(alloc).print("- Alias of: `{s}`\n", .{alias_of});
    }
    for (spec.description) |line| {
        if (line.len > 0) try out.writer(alloc).print("- {s}\n", .{line});
    }
    if (spec.options.len > 0) {
        try out.appendSlice(alloc, "- Options:\n");
        for (spec.options) |option| {
            try out.appendSlice(alloc, "  - `");
            for (option.forms, 0..) |form, i| {
                if (i > 0) try out.appendSlice(alloc, "`, `");
                try out.appendSlice(alloc, form);
                if (option.value_name) |value_name| {
                    try out.append(alloc, ' ');
                    try out.appendSlice(alloc, value_name);
                }
            }
            try out.writer(alloc).print("` — {s}\n", .{option.description});
        }
    }
    if (spec.positional.summary.len > 0) {
        try out.writer(alloc).print("- Arguments: {s}\n", .{spec.positional.summary});
    }
    try out.appendSlice(alloc, "- Output:\n");
    for (spec.output) |line| {
        try out.writer(alloc).print("  - {s}\n", .{line});
    }
    if (spec.examples.len > 0) {
        try out.appendSlice(alloc, "- Examples:\n");
        for (spec.examples) |line| {
            try out.writer(alloc).print("  - `{s}`\n", .{line});
        }
    }
    if (spec.notes.len > 0) {
        try out.appendSlice(alloc, "- Notes:\n");
        for (spec.notes) |line| {
            try out.writer(alloc).print("  - {s}\n", .{line});
        }
    }
    if (spec.platform_notes.len > 0) {
        try out.appendSlice(alloc, "- Platform notes:\n");
        for (spec.platform_notes) |line| {
            try out.writer(alloc).print("  - {s}\n", .{line});
        }
    }
    try out.append(alloc, '\n');
}

fn validateLaunchArgs(args: []const []const u8) ValidationError!void {
    var parsed = remote.launch.parseArgs(std.heap.page_allocator, args) catch |err| switch (err) {
        error.MissingValue => return error.MissingValue,
        error.InvalidValue, error.InvalidEnv => return error.InvalidValue,
        error.UnsupportedOption => return error.UnknownOption,
        else => return error.InvalidValue,
    };
    defer parsed.deinit(std.heap.page_allocator);
}

fn validateNewWindowArgs(args: []const []const u8) ValidationError!void {
    var rewritten: std.ArrayList([]const u8) = .empty;
    defer rewritten.deinit(std.heap.page_allocator);
    rewritten.append(std.heap.page_allocator, "--type") catch return error.InvalidValue;
    rewritten.append(std.heap.page_allocator, "os-window") catch return error.InvalidValue;
    rewritten.appendSlice(std.heap.page_allocator, args) catch return error.InvalidValue;
    try validateLaunchArgs(rewritten.items);
}

fn validateSendLineArgs(args: []const []const u8) ValidationError!void {
    const spec = &send_line_spec;
    try validateBySpec(spec, args);
}

const specs = [_]CommandSpec{
    .{
        .key = .action,
        .name = "action",
        .summary = "Run a binding action on the target surface or app.",
        .synopsis = "jterm @ action [options] <action-name>",
        .description = &.{"Run a binding action on the matched surface or app."},
        .positional = .{ .min = 1, .max = 1, .summary = "<action-name>" },
        .options = &.{ route_match, route_self, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default. Use `--response` to print the server envelope."},
        .examples = &.{"jterm @ action --match \"id:12\" clear_screen"},
    },
    .{
        .key = .close_tab,
        .name = "close-tab",
        .summary = "Close tab targets.",
        .synopsis = "jterm @ close-tab [options] [this|other|right]",
        .description = &.{"Close matched tabs or tab groups."},
        .positional = .{ .min = 0, .max = 1, .summary = "[this|other|right]" },
        .options = &.{ route_match, route_ignore_no_match, route_no_response, route_self },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .close_window,
        .name = "close-window",
        .summary = "Close window targets.",
        .synopsis = "jterm @ close-window --match <expr> [--ignore-no-match]",
        .description = &.{"Close matched windows."},
        .positional = .{},
        .options = &.{ route_match, route_ignore_no_match, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .examples = &.{"jterm @ close-window --match \"id:42\" --ignore-no-match"},
    },
    .{
        .key = .create_marker,
        .name = "create-marker",
        .summary = "Create a marker on the target window.",
        .synopsis = "jterm @ create-marker --match <expr> <marker>",
        .description = &.{"Create a marker such as `prompt` on the target window."},
        .positional = .{ .min = 1, .max = 1, .summary = "<marker>" },
        .options = &.{route_match},
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .detach_tab,
        .name = "detach-tab",
        .summary = "Detach a tab into its own OS window.",
        .synopsis = "jterm @ detach-tab [options]",
        .description = &.{"Detach the matched tab into its own OS window."},
        .options = &.{ route_match, .{ .forms = &.{ "--target-tab", "-t" }, .value_name = "expr", .value_kind = .required, .description = "Target a specific tab expression." }, route_self },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .detach_window,
        .name = "detach-window",
        .summary = "Detach a split into its own tab or window.",
        .synopsis = "jterm @ detach-window [options]",
        .description = &.{"Detach the matched terminal split from its current tab."},
        .options = &.{ route_match, .{ .forms = &.{ "--target-tab", "-t" }, .value_name = "expr", .value_kind = .required, .description = "Target a specific tab expression." }, route_self, .{ .forms = &.{"--stay-in-tab"}, .description = "Keep the detached window in the current tab layout when supported." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .disable_ligatures,
        .name = "disable-ligatures",
        .summary = "Toggle ligature rendering policy.",
        .synopsis = "jterm @ disable-ligatures [options] <always|never|cursor>",
        .description = &.{"Set ligature policy on matching windows."},
        .positional = .{ .min = 1, .max = 1, .summary = "<always|never|cursor>" },
        .options = &.{ route_all, route_match, route_match_tab },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .env,
        .name = "env",
        .summary = "Set environment metadata on target windows.",
        .synopsis = "jterm @ env --match <expr> KEY=VALUE [KEY=VALUE ...]",
        .description = &.{"Set or update environment metadata used for later matching."},
        .positional = .{ .min = 1, .max = null, .summary = "KEY=VALUE [KEY=VALUE ...]" },
        .options = &.{route_match},
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .focus_tab,
        .name = "focus-tab",
        .summary = "Focus the first matching tab.",
        .synopsis = "jterm @ focus-tab --match <expr>",
        .description = &.{"Focus the first matching tab."},
        .options = &.{ route_match, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .examples = &.{"jterm @ focus-tab --match \"id:7\""},
    },
    .{
        .key = .focus_window,
        .name = "focus-window",
        .summary = "Focus the first matching window.",
        .synopsis = "jterm @ focus-window --match <expr>",
        .description = &.{"Focus the first matching window."},
        .options = &.{ route_match, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .examples = &.{"jterm @ focus-window --match \"id:7\""},
    },
    .{ .key = .get_colors, .name = "get-colors", .summary = "Print colors for the matching window.", .synopsis = "jterm @ get-colors [options]", .description = &.{"Query configured or live colors for the matching window."}, .options = &.{ route_match, .{ .forms = &.{ "--configured", "-c" }, .description = "Print configured colors rather than live overrides." } }, .matching = matching_lines[0..], .output = &.{"Prints color information as lines of text."}, .output_kind = .colors, .response_behavior = .force_response },
    .{
        .key = .get_text,
        .name = "get-text",
        .summary = "Read text from a target window.",
        .synopsis = "jterm @ get-text [options]",
        .description = &.{"Read text from the target window or selection."},
        .options = &.{ route_match, .{ .forms = &.{"--extent"}, .value_name = "screen|all|selection|first_cmd_output_on_screen|last_cmd_output|last_visited_cmd_output|last_non_empty_output", .value_kind = .required, .description = "Choose which text extent to read." }, .{ .forms = &.{"--ansi"}, .description = "Include ANSI escape sequences." }, .{ .forms = &.{"--add-cursor"}, .description = "Include a cursor marker in the output." }, .{ .forms = &.{"--add-wrap-markers"}, .description = "Include wrap markers in the output." }, .{ .forms = &.{"--clear-selection"}, .description = "Clear the selection after reading it." }, route_self },
        .matching = matching_lines[0..],
        .output = &.{"Prints the requested text to stdout."},
        .output_kind = .text,
        .response_behavior = .force_response,
        .examples = &.{"jterm @ get-text --match \"id:5\" --extent screen"},
    },
    .{
        .key = .goto_layout,
        .name = "goto-layout",
        .summary = "Change the layout on a matching window.",
        .synopsis = "jterm @ goto-layout --match <expr> <layout>",
        .description = &.{"Change the target window layout, for example `stack` or `splits`."},
        .positional = .{ .min = 1, .max = 1, .summary = "<layout>" },
        .options = &.{route_match},
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .kitten,
        .name = "kitten",
        .summary = "Run a kitten-style helper command.",
        .synopsis = "jterm @ kitten --match <expr> <kitten-name> [args...]",
        .description = &.{"Run a kitten-style helper command on the target window."},
        .positional = .{ .min = 1, .max = null, .summary = "<kitten-name> [args...]" },
        .options = &.{route_match},
        .matching = matching_lines[0..],
        .output = &.{"Command-specific output. Use `--response` when you need the raw response envelope."},
    },
    .{
        .key = .last_used_layout,
        .name = "last-used-layout",
        .summary = "Restore the previous layout.",
        .synopsis = "jterm @ last-used-layout [options]",
        .description = &.{"Restore the previously used layout on matching windows."},
        .options = &.{ route_all, route_match, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{ .key = .launch, .name = "launch", .summary = "Open a new terminal window and optionally run setup text or a command.", .synopsis = "jterm @ launch [launch options] [-- command ...]", .description = &.{"Canonical way to create a new window for automation workflows."}, .positional = .{ .min = 0, .max = null, .summary = "[command ...]" }, .options = &.{ .{ .forms = &.{"--type"}, .value_name = "os-window|window", .value_kind = .required, .description = "Select the launch type. Use `os-window` for canonical agent workflows." }, .{ .forms = &.{"--title"}, .value_name = "text", .value_kind = .required, .description = "Set the new window title." }, .{ .forms = &.{"--cwd"}, .value_name = "path", .value_kind = .required, .description = "Change to this directory before running the command." }, .{ .forms = &.{"--env"}, .value_name = "KEY=VALUE", .value_kind = .required, .repeatable = true, .description = "Inject environment variables into the launched shell context." }, .{ .forms = &.{"--os-window-state"}, .value_name = "normal|maximized|minimized|hidden", .value_kind = .required, .description = "Apply an initial OS-window state." } }, .output = &.{"Prints the created window id on success."}, .output_kind = .id, .response_behavior = .force_response, .examples = &.{ "jterm @ launch --type os-window --title \"Claude Chat\"", "jterm @ launch --type os-window --title \"Claude Chat\" --cwd ~/code/misc", "jterm @ launch --type os-window --cwd ~/code/misc -- claude" }, .notes = &.{"Capture the returned id and use `id:<n>` matching for all follow-up commands."}, .validator = &validateLaunchArgs },
    .{
        .key = .load_config,
        .name = "load-config",
        .summary = "Reload the active jTerm config file.",
        .synopsis = "jterm @ load-config [options]",
        .description = &.{"Reload the active config file in the running jTerm app."},
        .options = &.{ .{ .forms = &.{"--ignore-overrides"}, .description = "Ignore runtime overrides when loading config." }, .{ .forms = &.{ "--override", "-o" }, .value_name = "key=value", .value_kind = .required, .repeatable = true, .description = "Apply a temporary override while reloading config." }, route_no_response },
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .ls,
        .name = "ls",
        .summary = "List live windows and tabs as JSON.",
        .synopsis = "jterm @ ls [options]",
        .description = &.{"List live windows, tabs, and surfaces as JSON."},
        .options = &.{ route_match, route_match_tab, .{ .forms = &.{"--all-env-vars"}, .description = "Include all exported environment values in the JSON output." }, route_self, .{ .forms = &.{"--output-format"}, .value_name = "json", .value_kind = .required, .description = "Select the output format. `json` is the stable form." } },
        .matching = matching_lines[0..],
        .output = &.{"Prints a JSON object describing live windows, tabs, and surfaces."},
        .output_kind = .json,
        .response_behavior = .force_response,
        .examples = &.{"jterm @ ls | jq '.surfaces[] | {id, title, cwd}'"},
    },
    .{
        .key = .new_tab,
        .name = "new-tab",
        .summary = "Create a new tab in the focused window.",
        .synopsis = "jterm @ new-tab",
        .description = &.{"Create a new tab in the focused window."},
        .output = &.{"Prints the created tab or surface id when the server returns one."},
        .output_kind = .id,
        .response_behavior = .force_response,
    },
    .{ .key = .new_window, .name = "new-window", .summary = "Convenience alias for launch --type os-window.", .synopsis = "jterm @ new-window [window options]", .description = &.{"Supported sugar over `launch --type os-window`."}, .options = &.{ .{ .forms = &.{"--title"}, .value_name = "text", .value_kind = .required, .description = "Set the new window title." }, .{ .forms = &.{"--cwd"}, .value_name = "path", .value_kind = .required, .description = "Change to this directory before running startup text." }, .{ .forms = &.{"--env"}, .value_name = "KEY=VALUE", .value_kind = .required, .repeatable = true, .description = "Inject environment variables into the launched shell context." }, .{ .forms = &.{"--os-window-state"}, .value_name = "normal|maximized|minimized|hidden", .value_kind = .required, .description = "Apply an initial OS-window state." } }, .output = &.{"Prints the created window id on success."}, .output_kind = .id, .response_behavior = .force_response, .examples = &.{"jterm @ new-window --title \"Claude Chat\" --cwd ~/code/misc"}, .notes = &.{"Agents should prefer `launch --type os-window`, but this alias is fully supported."}, .alias_of = "launch --type os-window", .validator = &validateNewWindowArgs },
    .{
        .key = .remove_marker,
        .name = "remove-marker",
        .summary = "Remove a marker from the target window.",
        .synopsis = "jterm @ remove-marker --match <expr> <marker>",
        .description = &.{"Remove a marker such as `prompt` from the target window."},
        .positional = .{ .min = 1, .max = 1, .summary = "<marker>" },
        .options = &.{route_match},
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .move_os_window,
        .name = "move-os-window",
        .summary = "Move the matched OS window to a monitor.",
        .synopsis = "jterm @ move-os-window --match <expr> --monitor <n|mN|current>",
        .description = &.{"Move the matched OS window to a target monitor."},
        .options = &.{ route_match, .{ .forms = &.{"--monitor"}, .value_name = "n|mN|current|active|this", .value_kind = .required, .description = "Choose the target monitor by numeric slot or current monitor alias." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .examples = &.{ "jterm @ move-os-window --match \"id:5\" --monitor 4", "jterm @ move-os-window --match \"id:5\" --monitor m2" },
        .platform_notes = &.{"Monitor targeting is meaningful for OS-window management on macOS."},
    },
    .{
        .key = .maximize_os_window,
        .name = "maximize-os-window",
        .summary = "Maximize a matched OS window.",
        .synopsis = "jterm @ maximize-os-window --match <expr> [--monitor <n|mN|current>]",
        .description = &.{"Maximize the matched OS window, optionally on a specific monitor."},
        .options = &.{ route_match, .{ .forms = &.{"--monitor"}, .value_name = "n|mN|current|active|this", .value_kind = .required, .description = "Choose the monitor context when supported." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .platform_notes = &.{"OS-window semantics are platform-specific."},
    },
    .{
        .key = .minimize_os_window,
        .name = "minimize-os-window",
        .summary = "Minimize a matched OS window.",
        .synopsis = "jterm @ minimize-os-window --match <expr> [--monitor <n|mN|current>]",
        .description = &.{"Minimize the matched OS window."},
        .options = &.{ route_match, .{ .forms = &.{"--monitor"}, .value_name = "n|mN|current|active|this", .value_kind = .required, .description = "Choose the monitor context when supported." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .platform_notes = &.{"OS-window semantics are platform-specific."},
    },
    .{
        .key = .hide_os_window,
        .name = "hide-os-window",
        .summary = "Hide a matched OS window.",
        .synopsis = "jterm @ hide-os-window --match <expr> [--monitor <n|mN|current>]",
        .description = &.{"Hide the matched OS window."},
        .options = &.{ route_match, .{ .forms = &.{"--monitor"}, .value_name = "n|mN|current|active|this", .value_kind = .required, .description = "Choose the monitor context when supported." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .platform_notes = &.{"OS-window semantics are platform-specific."},
    },
    .{
        .key = .snap_os_window,
        .name = "snap-os-window",
        .summary = "Snap an OS window to a side or quadrant.",
        .synopsis = "jterm @ snap-os-window --match <expr> <left|right|quadrant1|quadrant2|quadrant3|quadrant4> [--monitor <n|mN|current>]",
        .description = &.{"Snap the OS window to a side or quadrant on the selected monitor."},
        .positional = .{ .min = 1, .max = 1, .summary = "<left|right|quadrant1|quadrant2|quadrant3|quadrant4>" },
        .options = &.{ route_match, .{ .forms = &.{"--monitor"}, .value_name = "n|mN|current|active|this", .value_kind = .required, .description = "Choose the monitor context when supported." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .notes = &.{"Quadrant aliases include q1/top-left, q2/top-right, q3/bottom-left, q4/bottom-right."},
        .platform_notes = &.{"OS-window semantics are platform-specific."},
    },
    .{
        .key = .resize_os_window,
        .name = "resize-os-window",
        .summary = "Resize the host OS window.",
        .synopsis = "jterm @ resize-os-window --match <expr> <WIDTHxHEIGHT | --width N --height N>",
        .description = &.{"Resize the host OS window using cell dimensions."},
        .positional = .{ .min = 0, .max = 1, .summary = "[WIDTHxHEIGHT]" },
        .options = &.{ route_match, .{ .forms = &.{"--action"}, .value_name = "resize|toggle-fullscreen|toggle-maximized", .value_kind = .required, .description = "Choose an OS-window action." }, .{ .forms = &.{"--unit"}, .value_name = "cells|pixels", .value_kind = .required, .description = "Set the resize unit." }, .{ .forms = &.{"--width"}, .value_name = "N", .value_kind = .required, .description = "Set the width." }, .{ .forms = &.{"--height"}, .value_name = "N", .value_kind = .required, .description = "Set the height." }, .{ .forms = &.{"--incremental"}, .description = "Treat width and height as increments." }, route_self, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .examples = &.{ "jterm @ resize-os-window --match \"id:5\" 120x40", "jterm @ resize-os-window --match \"id:5\" --width 120 --height 40" },
        .platform_notes = &.{"OS-window semantics are platform-specific."},
    },
    .{
        .key = .resize_window,
        .name = "resize-window",
        .summary = "Resize a split or terminal pane.",
        .synopsis = "jterm @ resize-window --match <expr> <wider|narrower|taller|shorter|reset> [amount]",
        .description = &.{"Resize a split or terminal pane inside the current window."},
        .positional = .{ .min = 1, .max = 2, .summary = "<wider|narrower|taller|shorter|reset> [amount]" },
        .options = &.{ route_match, .{ .forms = &.{ "--increment", "-i" }, .value_name = "N", .value_kind = .required, .description = "Set the resize increment." }, .{ .forms = &.{ "--axis", "-a" }, .value_name = "horizontal|vertical|reset", .value_kind = .required, .description = "Choose the resize axis." }, route_self },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .run,
        .name = "run",
        .summary = "Run a command and return its stdout.",
        .synopsis = "jterm @ run [options] <command> [args...]",
        .description = &.{"Run a command and return its stdout."},
        .positional = .{ .min = 1, .max = null, .summary = "<command> [args...]" },
        .options = &.{ .{ .forms = &.{"--env"}, .value_name = "KEY=VALUE", .value_kind = .required, .repeatable = true, .description = "Inject environment variables into the launched command." }, .{ .forms = &.{"--allow-remote-control"}, .description = "Allow remote-control in the launched child if supported." }, .{ .forms = &.{"--remote-control-password"}, .value_name = "password", .value_kind = .required, .description = "Set the remote-control password for the child." } },
        .output = &.{"Prints the child command stdout when available."},
        .output_kind = .run_stdout,
        .response_behavior = .force_response,
    },
    .{
        .key = .scroll_window,
        .name = "scroll-window",
        .summary = "Scroll a window by amount or to an endpoint.",
        .synopsis = "jterm @ scroll-window [options] <amount|start|end>",
        .description = &.{"Scroll a window by line count or jump to start/end."},
        .positional = .{ .min = 1, .max = 1, .summary = "<amount|start|end>" },
        .options = &.{ route_match, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .select_window,
        .name = "select-window",
        .summary = "Interactive focus flow for choosing a window.",
        .synopsis = "jterm @ select-window [options]",
        .description = &.{"Interactive select-style focus flow. If only one target matches, it focuses immediately."},
        .options = &.{ route_match, route_response_timeout, route_self, .{ .forms = &.{"--title"}, .value_name = "text", .value_kind = .required, .description = "Override the selection UI title." }, .{ .forms = &.{"--exclude-active"}, .description = "Exclude the active window from the selection list." }, .{ .forms = &.{"--reactivate-prev-tab"}, .description = "Return focus to the previous tab after selection when supported." } },
        .matching = matching_lines[0..],
        .output = &.{"Prints `1` when focus was transferred."},
        .output_kind = .focused_flag,
        .response_behavior = .force_response,
    },
    .{
        .key = .send_key,
        .name = "send-key",
        .summary = "Send one or more literal key presses.",
        .synopsis = "jterm @ send-key [routing options] <key> [key ...]",
        .description = &.{"Send one or more literal key presses such as enter, escape, or ctrl+c."},
        .positional = .{ .min = 1, .max = null, .summary = "<key> [key ...]" },
        .options = &.{ route_match, route_match_tab, route_all, .{ .forms = &.{"--exclude-active"}, .description = "Skip the active target when broadcasting." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .send_text,
        .name = "send-text",
        .summary = "Send text without synthesizing Enter unless requested.",
        .synopsis = "jterm @ send-text [routing options] [text options] <text>",
        .description = &.{"Send text to the matched target."},
        .positional = .{ .min = 1, .max = null, .summary = "<text>" },
        .options = &.{ route_match, route_match_tab, route_all, .{ .forms = &.{"--exclude-active"}, .description = "Skip the active target when broadcasting." }, .{ .forms = &.{"--stdin"}, .description = "Read the text payload from stdin." }, .{ .forms = &.{"--from-file"}, .value_name = "path", .value_kind = .required, .description = "Read the text payload from a file." }, .{ .forms = &.{"--bracketed-paste"}, .value_name = "disable|enable", .value_kind = .required, .description = "Control bracketed-paste wrapping for the payload." }, .{ .forms = &.{"--submit"}, .value_name = "none|enter|assistant", .value_kind = .required, .description = "Optionally submit after sending text." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
        .notes = &.{"Use `send-line` when the user intent is to submit text. Do not embed literal `\\n` or `\\r` for assistant TUIs."},
    },
    .{
        .key = .set_background_image,
        .name = "set-background-image",
        .summary = "Set a background image on matching windows.",
        .synopsis = "jterm @ set-background-image [options] <path>",
        .description = &.{"Set a background image on matching windows."},
        .positional = .{ .min = 1, .max = 1, .summary = "<path>" },
        .options = &.{ route_all, .{ .forms = &.{ "--configured", "-c" }, .description = "Use configured defaults where applicable." }, .{ .forms = &.{"--layout"}, .value_name = "configured|tiled|centered|scaled", .value_kind = .required, .description = "Choose the background image layout." }, route_match, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_background_opacity,
        .name = "set-background-opacity",
        .summary = "Set or toggle background opacity.",
        .synopsis = "jterm @ set-background-opacity [options] <opacity>",
        .description = &.{"Set or toggle background opacity."},
        .positional = .{ .min = 1, .max = 1, .summary = "<opacity>" },
        .options = &.{ route_all, .{ .forms = &.{"--toggle"}, .description = "Toggle the current opacity override." }, route_match, route_match_tab },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_colors,
        .name = "set-colors",
        .summary = "Apply color overrides.",
        .synopsis = "jterm @ set-colors [options] KEY=VALUE [KEY=VALUE ...]",
        .description = &.{"Apply color overrides such as `foreground=#ffffff`."},
        .positional = .{ .min = 1, .max = null, .summary = "KEY=VALUE [KEY=VALUE ...]" },
        .options = &.{ route_all, .{ .forms = &.{ "--configured", "-c" }, .description = "Use configured defaults where applicable." }, .{ .forms = &.{"--reset"}, .description = "Reset the color override state." }, route_match, route_match_tab },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_enabled_layouts,
        .name = "set-enabled-layouts",
        .summary = "Set the enabled layout list.",
        .synopsis = "jterm @ set-enabled-layouts [options] <layout1,layout2,...>",
        .description = &.{"Set the enabled layouts list on matching windows."},
        .positional = .{ .min = 1, .max = 1, .summary = "<layout1,layout2,...>" },
        .options = &.{ route_match, .{ .forms = &.{ "--configured", "-c" }, .description = "Use configured defaults where applicable." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_font_size,
        .name = "set-font-size",
        .summary = "Set the font size override.",
        .synopsis = "jterm @ set-font-size [options] <points>",
        .description = &.{"Set the font size override."},
        .positional = .{ .min = 1, .max = 1, .summary = "<points>" },
        .options = &.{route_all},
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_spacing,
        .name = "set-spacing",
        .summary = "Set spacing or padding overrides.",
        .synopsis = "jterm @ set-spacing [options] <key=value> [key=value ...]",
        .description = &.{"Set spacing or padding overrides such as `padding=10`."},
        .positional = .{ .min = 1, .max = null, .summary = "<key=value> [key=value ...]" },
        .options = &.{ route_all, .{ .forms = &.{ "--configured", "-c" }, .description = "Use configured defaults where applicable." }, route_match, route_match_tab },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_tab_color,
        .name = "set-tab-color",
        .summary = "Set tab colors on the matched tab.",
        .synopsis = "jterm @ set-tab-color [options] <color-or-key=value> [more...]",
        .description = &.{"Set tab colors on the matched tab."},
        .positional = .{ .min = 1, .max = null, .summary = "<color-or-key=value> [more...]" },
        .options = &.{ route_match, route_self },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_tab_title,
        .name = "set-tab-title",
        .summary = "Set the title of the matching tab.",
        .synopsis = "jterm @ set-tab-title [options] <title>",
        .description = &.{"Set the title of the matching tab."},
        .positional = .{ .min = 1, .max = 1, .summary = "<title>" },
        .options = &.{route_match},
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_user_vars,
        .name = "set-user-vars",
        .summary = "Set user variables for later matching.",
        .synopsis = "jterm @ set-user-vars --match <expr> KEY=VALUE [KEY=VALUE ...]",
        .description = &.{"Set user variables for later matching or metadata."},
        .positional = .{ .min = 1, .max = null, .summary = "KEY=VALUE [KEY=VALUE ...]" },
        .options = &.{route_match},
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_window_logo,
        .name = "set-window-logo",
        .summary = "Set a window logo image.",
        .synopsis = "jterm @ set-window-logo [options] <path>",
        .description = &.{"Set a window logo image."},
        .positional = .{ .min = 1, .max = 1, .summary = "<path>" },
        .options = &.{ route_match, route_self, .{ .forms = &.{"--position"}, .value_name = "corner", .value_kind = .required, .description = "Place the logo in a specific corner or anchor." }, .{ .forms = &.{"--alpha"}, .value_name = "0..1", .value_kind = .required, .description = "Set the logo alpha." }, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .set_window_title,
        .name = "set-window-title",
        .summary = "Set the title of the matching window.",
        .synopsis = "jterm @ set-window-title [options] <title>",
        .description = &.{"Set the title of the matching window."},
        .positional = .{ .min = 1, .max = 1, .summary = "<title>" },
        .options = &.{ route_match, .{ .forms = &.{"--temporary"}, .description = "Set a temporary title that may later be replaced by app state." } },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
    .{
        .key = .signal_child,
        .name = "signal-child",
        .summary = "Send a signal to a child process.",
        .synopsis = "jterm @ signal-child --match <expr> <signal>",
        .description = &.{"Send a signal such as `SIGTERM` to the child process of the target window."},
        .positional = .{ .min = 1, .max = 1, .summary = "<signal>" },
        .options = &.{ route_match, route_no_response },
        .matching = matching_lines[0..],
        .output = &.{"Silent by default unless `--response` is set."},
    },
};

const send_line_spec = CommandSpec{
    .key = null,
    .name = "send-line",
    .summary = "Send text and then press Enter.",
    .synopsis = "jterm @ send-line [routing options] <text>",
    .description = &.{ "Submit one line of text by sending text and then Enter.", "Recommended for shell commands and assistant TUIs such as Claude Code or Codex." },
    .positional = .{ .min = 1, .max = null, .summary = "<text>" },
    .options = &.{ route_match, route_match_tab, route_all, .{ .forms = &.{"--exclude-active"}, .description = "Skip the active target when broadcasting." } },
    .matching = matching_lines[0..],
    .output = &.{"Silent by default unless `--response` is set."},
    .notes = &.{ "Equivalent to `send-text` followed by `send-key enter`.", "Use this when the intent is to submit, rather than pasting literal newlines." },
    .examples = &.{ "jterm @ send-line --match \"id:5\" \"pwd\"", "jterm @ send-line --match \"id:5\" \"Who was the 34th president?\"" },
    .alias_of = "send-text + send-key enter",
    .validator = &validateSendLineArgs,
};

const command_names_with_aliases = [_][]const u8{
    "action",
    "close-tab",
    "close-window",
    "create-marker",
    "detach-tab",
    "detach-window",
    "disable-ligatures",
    "env",
    "focus-tab",
    "focus-window",
    "get-colors",
    "get-text",
    "goto-layout",
    "kitten",
    "last-used-layout",
    "launch",
    "load-config",
    "ls",
    "new-tab",
    "new-window",
    "remove-marker",
    "move-os-window",
    "maximize-os-window",
    "minimize-os-window",
    "hide-os-window",
    "snap-os-window",
    "resize-os-window",
    "resize-window",
    "run",
    "scroll-window",
    "select-window",
    "send-key",
    "send-line",
    "send-text",
    "set-background-image",
    "set-background-opacity",
    "set-colors",
    "set-enabled-layouts",
    "set-font-size",
    "set-spacing",
    "set-tab-color",
    "set-tab-title",
    "set-user-vars",
    "set-window-logo",
    "set-window-title",
    "signal-child",
};

test "every remote command has a schema spec" {
    const testing = std.testing;
    for (remote.command.all) |cmd| {
        const spec = specForKey(cmd);
        try testing.expect(spec.name.len > 0);
        try testing.expect(spec.summary.len > 0);
        try testing.expect(spec.synopsis.len > 0);
        try testing.expect(spec.output.len > 0);
    }
}

test "renderGlobalHelp lists send-line and launch" {
    const testing = std.testing;
    const text = try renderGlobalHelp(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "send-line") != null);
    try testing.expect(std.mem.indexOf(u8, text, "launch") != null);
}

test "generated command reference doc is in sync" {
    const testing = std.testing;
    const generated = try renderReferenceDoc(testing.allocator);
    defer testing.allocator.free(generated);

    const checked_in = try std.fs.cwd().readFileAlloc(
        testing.allocator,
        "docs/JTERM_REMOTE_CONTROL_COMMAND_REFERENCE.md",
        1024 * 1024,
    );
    defer testing.allocator.free(checked_in);

    try testing.expectEqualStrings(checked_in, generated);
}

test "generated manpage doc is in sync" {
    const testing = std.testing;
    const generated = try renderManpageDoc(testing.allocator);
    defer testing.allocator.free(generated);

    const checked_in = try std.fs.cwd().readFileAlloc(
        testing.allocator,
        "docs/JTERM_REMOTE_CONTROL_CLI_MANPAGE.md",
        1024 * 1024,
    );
    defer testing.allocator.free(checked_in);

    try testing.expectEqualStrings(checked_in, generated);
}
