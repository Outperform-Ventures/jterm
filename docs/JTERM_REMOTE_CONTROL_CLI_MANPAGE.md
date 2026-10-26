# JTERM-RC(1)

## NAME

jterm @ - control a running jTerm instance over the remote-control socket

## SYNOPSIS

`jterm @ [global options] <command> [command options] [command args]`

## DESCRIPTION

The `jterm @` command sends kitty-compatible remote-control requests to a running jTerm app.
The canonical automation workflow is: create or discover a window, capture its id, then use
`id:<n>` matching for all follow-up operations. Use `send-line` when the intent is to submit text.

## GLOBAL OPTIONS
- `--to unix:/path.sock` — Override the remote-control socket target.
- `--password token` — Provide the remote-control password directly.
- `--password-file path` — Read the remote-control password from a file.
- `--password-env ENV_NAME` — Read the remote-control password from an environment variable.
- `--use-password if-available|always|never` — Control whether password transport is used.
- `--help`, `-h` — Show global help or command-specific help.

## EXIT STATUS
- `0  success`
- `2  usage or validation error`
- `3  target selection failure`
- `4  transport or authentication failure`
- `5  remote action failure`
- `6  unsupported capability or platform constraint`

## COMMANDS
### `action`

- Summary: Run a binding action on the target surface or app.
- Synopsis: `jterm @ action [options] <action-name>`
- Run a binding action on the matched surface or app.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--self` — Scope the command to the current terminal context when supported.
  - `--no-response` — Suppress the response body for this invocation.
- Arguments: <action-name>
- Output:
  - Silent by default. Use `--response` to print the server envelope.
- Examples:
  - `jterm @ action --match "id:12" clear_screen`

### `close-tab`

- Summary: Close tab targets.
- Synopsis: `jterm @ close-tab [options] [this|other|right]`
- Close matched tabs or tab groups.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--ignore-no-match` — Exit successfully when no targets match.
  - `--no-response` — Suppress the response body for this invocation.
  - `--self` — Scope the command to the current terminal context when supported.
- Arguments: [this|other|right]
- Output:
  - Silent by default unless `--response` is set.

### `close-window`

- Summary: Close window targets.
- Synopsis: `jterm @ close-window --match <expr> [--ignore-no-match]`
- Close matched windows.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--ignore-no-match` — Exit successfully when no targets match.
  - `--no-response` — Suppress the response body for this invocation.
- Output:
  - Silent by default unless `--response` is set.
- Examples:
  - `jterm @ close-window --match "id:42" --ignore-no-match`

### `create-marker`

- Summary: Create a marker on the target window.
- Synopsis: `jterm @ create-marker --match <expr> <marker>`
- Create a marker such as `prompt` on the target window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
- Arguments: <marker>
- Output:
  - Silent by default unless `--response` is set.

### `detach-tab`

- Summary: Detach a tab into its own OS window.
- Synopsis: `jterm @ detach-tab [options]`
- Detach the matched tab into its own OS window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--target-tab expr`, `-t expr` — Target a specific tab expression.
  - `--self` — Scope the command to the current terminal context when supported.
- Output:
  - Silent by default unless `--response` is set.

### `detach-window`

- Summary: Detach a split into its own tab or window.
- Synopsis: `jterm @ detach-window [options]`
- Detach the matched terminal split from its current tab.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--target-tab expr`, `-t expr` — Target a specific tab expression.
  - `--self` — Scope the command to the current terminal context when supported.
  - `--stay-in-tab` — Keep the detached window in the current tab layout when supported.
- Output:
  - Silent by default unless `--response` is set.

### `disable-ligatures`

- Summary: Toggle ligature rendering policy.
- Synopsis: `jterm @ disable-ligatures [options] <always|never|cursor>`
- Set ligature policy on matching windows.
- Options:
  - `--all`, `-a` — Apply the command to every matching target.
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
- Arguments: <always|never|cursor>
- Output:
  - Silent by default unless `--response` is set.

### `env`

- Summary: Set environment metadata on target windows.
- Synopsis: `jterm @ env --match <expr> KEY=VALUE [KEY=VALUE ...]`
- Set or update environment metadata used for later matching.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
- Arguments: KEY=VALUE [KEY=VALUE ...]
- Output:
  - Silent by default unless `--response` is set.

### `focus-tab`

- Summary: Focus the first matching tab.
- Synopsis: `jterm @ focus-tab --match <expr>`
- Focus the first matching tab.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--no-response` — Suppress the response body for this invocation.
- Output:
  - Silent by default unless `--response` is set.
- Examples:
  - `jterm @ focus-tab --match "id:7"`

### `focus-window`

- Summary: Focus the first matching window.
- Synopsis: `jterm @ focus-window --match <expr>`
- Focus the first matching window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--no-response` — Suppress the response body for this invocation.
- Output:
  - Silent by default unless `--response` is set.
- Examples:
  - `jterm @ focus-window --match "id:7"`

### `get-colors`

- Summary: Print colors for the matching window.
- Synopsis: `jterm @ get-colors [options]`
- Query configured or live colors for the matching window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--configured`, `-c` — Print configured colors rather than live overrides.
- Output:
  - Prints color information as lines of text.

### `get-text`

- Summary: Read text from a target window.
- Synopsis: `jterm @ get-text [options]`
- Read text from the target window or selection.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--extent screen|all|selection|first_cmd_output_on_screen|last_cmd_output|last_visited_cmd_output|last_non_empty_output` — Choose which text extent to read.
  - `--ansi` — Include ANSI escape sequences.
  - `--add-cursor` — Include a cursor marker in the output.
  - `--add-wrap-markers` — Include wrap markers in the output.
  - `--clear-selection` — Clear the selection after reading it.
  - `--self` — Scope the command to the current terminal context when supported.
- Output:
  - Prints the requested text to stdout.
- Examples:
  - `jterm @ get-text --match "id:5" --extent screen`

### `goto-layout`

- Summary: Change the layout on a matching window.
- Synopsis: `jterm @ goto-layout --match <expr> <layout>`
- Change the target window layout, for example `stack` or `splits`.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
- Arguments: <layout>
- Output:
  - Silent by default unless `--response` is set.

### `kitten`

- Summary: Run a kitten-style helper command.
- Synopsis: `jterm @ kitten --match <expr> <kitten-name> [args...]`
- Run a kitten-style helper command on the target window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
- Arguments: <kitten-name> [args...]
- Output:
  - Command-specific output. Use `--response` when you need the raw response envelope.

### `last-used-layout`

- Summary: Restore the previous layout.
- Synopsis: `jterm @ last-used-layout [options]`
- Restore the previously used layout on matching windows.
- Options:
  - `--all`, `-a` — Apply the command to every matching target.
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--no-response` — Suppress the response body for this invocation.
- Output:
  - Silent by default unless `--response` is set.

### `launch`

- Summary: Open a new terminal window and optionally run setup text or a command.
- Synopsis: `jterm @ launch [launch options] [-- command ...]`
- Canonical way to create a new window for automation workflows.
- Options:
  - `--type os-window|window` — Select the launch type. Use `os-window` for canonical agent workflows.
  - `--title text` — Set the new window title.
  - `--cwd path` — Change to this directory before running the command.
  - `--env KEY=VALUE` — Inject environment variables into the launched shell context.
  - `--os-window-state normal|maximized|minimized|hidden` — Apply an initial OS-window state.
- Arguments: [command ...]
- Output:
  - Prints the created window id on success.
- Examples:
  - `jterm @ launch --type os-window --title "Claude Chat"`
  - `jterm @ launch --type os-window --title "Claude Chat" --cwd ~/code/misc`
  - `jterm @ launch --type os-window --cwd ~/code/misc -- claude`
- Notes:
  - Capture the returned id and use `id:<n>` matching for all follow-up commands.

### `load-config`

- Summary: Reload the active jTerm config file.
- Synopsis: `jterm @ load-config [options]`
- Reload the active config file in the running jTerm app.
- Options:
  - `--ignore-overrides` — Ignore runtime overrides when loading config.
  - `--override key=value`, `-o key=value` — Apply a temporary override while reloading config.
  - `--no-response` — Suppress the response body for this invocation.
- Output:
  - Silent by default unless `--response` is set.

### `ls`

- Summary: List live windows and tabs as JSON.
- Synopsis: `jterm @ ls [options]`
- List live windows, tabs, and surfaces as JSON.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
  - `--all-env-vars` — Include all exported environment values in the JSON output.
  - `--self` — Scope the command to the current terminal context when supported.
  - `--output-format json` — Select the output format. `json` is the stable form.
- Output:
  - Prints a JSON object describing live windows, tabs, and surfaces.
- Examples:
  - `jterm @ ls | jq '.surfaces[] | {id, title, cwd}'`

### `new-tab`

- Summary: Create a new tab in the focused window.
- Synopsis: `jterm @ new-tab`
- Create a new tab in the focused window.
- Output:
  - Prints the created tab or surface id when the server returns one.

### `new-window`

- Summary: Convenience alias for launch --type os-window.
- Synopsis: `jterm @ new-window [window options]`
- Alias of: `launch --type os-window`
- Supported sugar over `launch --type os-window`.
- Options:
  - `--title text` — Set the new window title.
  - `--cwd path` — Change to this directory before running startup text.
  - `--env KEY=VALUE` — Inject environment variables into the launched shell context.
  - `--os-window-state normal|maximized|minimized|hidden` — Apply an initial OS-window state.
- Output:
  - Prints the created window id on success.
- Examples:
  - `jterm @ new-window --title "Claude Chat" --cwd ~/code/misc`
- Notes:
  - Agents should prefer `launch --type os-window`, but this alias is fully supported.

### `remove-marker`

- Summary: Remove a marker from the target window.
- Synopsis: `jterm @ remove-marker --match <expr> <marker>`
- Remove a marker such as `prompt` from the target window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
- Arguments: <marker>
- Output:
  - Silent by default unless `--response` is set.

### `move-os-window`

- Summary: Move the matched OS window to a monitor.
- Synopsis: `jterm @ move-os-window --match <expr> --monitor <n|mN|current>`
- Move the matched OS window to a target monitor.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--monitor n|mN|current|active|this` — Choose the target monitor by numeric slot or current monitor alias.
- Output:
  - Silent by default unless `--response` is set.
- Examples:
  - `jterm @ move-os-window --match "id:5" --monitor 4`
  - `jterm @ move-os-window --match "id:5" --monitor m2`
- Platform notes:
  - Monitor targeting is meaningful for OS-window management on macOS.

### `maximize-os-window`

- Summary: Maximize a matched OS window.
- Synopsis: `jterm @ maximize-os-window --match <expr> [--monitor <n|mN|current>]`
- Maximize the matched OS window, optionally on a specific monitor.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--monitor n|mN|current|active|this` — Choose the monitor context when supported.
- Output:
  - Silent by default unless `--response` is set.
- Platform notes:
  - OS-window semantics are platform-specific.

### `minimize-os-window`

- Summary: Minimize a matched OS window.
- Synopsis: `jterm @ minimize-os-window --match <expr> [--monitor <n|mN|current>]`
- Minimize the matched OS window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--monitor n|mN|current|active|this` — Choose the monitor context when supported.
- Output:
  - Silent by default unless `--response` is set.
- Platform notes:
  - OS-window semantics are platform-specific.

### `hide-os-window`

- Summary: Hide a matched OS window.
- Synopsis: `jterm @ hide-os-window --match <expr> [--monitor <n|mN|current>]`
- Hide the matched OS window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--monitor n|mN|current|active|this` — Choose the monitor context when supported.
- Output:
  - Silent by default unless `--response` is set.
- Platform notes:
  - OS-window semantics are platform-specific.

### `snap-os-window`

- Summary: Snap an OS window to a side or quadrant.
- Synopsis: `jterm @ snap-os-window --match <expr> <left|right|quadrant1|quadrant2|quadrant3|quadrant4> [--monitor <n|mN|current>]`
- Snap the OS window to a side or quadrant on the selected monitor.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--monitor n|mN|current|active|this` — Choose the monitor context when supported.
- Arguments: <left|right|quadrant1|quadrant2|quadrant3|quadrant4>
- Output:
  - Silent by default unless `--response` is set.
- Notes:
  - Quadrant aliases include q1/top-left, q2/top-right, q3/bottom-left, q4/bottom-right.
- Platform notes:
  - OS-window semantics are platform-specific.

### `resize-os-window`

- Summary: Resize the host OS window.
- Synopsis: `jterm @ resize-os-window --match <expr> <WIDTHxHEIGHT | --width N --height N>`
- Resize the host OS window using cell dimensions.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--action resize|toggle-fullscreen|toggle-maximized` — Choose an OS-window action.
  - `--unit cells|pixels` — Set the resize unit.
  - `--width N` — Set the width.
  - `--height N` — Set the height.
  - `--incremental` — Treat width and height as increments.
  - `--self` — Scope the command to the current terminal context when supported.
  - `--no-response` — Suppress the response body for this invocation.
- Arguments: [WIDTHxHEIGHT]
- Output:
  - Silent by default unless `--response` is set.
- Examples:
  - `jterm @ resize-os-window --match "id:5" 120x40`
  - `jterm @ resize-os-window --match "id:5" --width 120 --height 40`
- Platform notes:
  - OS-window semantics are platform-specific.

### `resize-window`

- Summary: Resize a split or terminal pane.
- Synopsis: `jterm @ resize-window --match <expr> <wider|narrower|taller|shorter|reset> [amount]`
- Resize a split or terminal pane inside the current window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--increment N`, `-i N` — Set the resize increment.
  - `--axis horizontal|vertical|reset`, `-a horizontal|vertical|reset` — Choose the resize axis.
  - `--self` — Scope the command to the current terminal context when supported.
- Arguments: <wider|narrower|taller|shorter|reset> [amount]
- Output:
  - Silent by default unless `--response` is set.

### `run`

- Summary: Run a command and return its stdout.
- Synopsis: `jterm @ run [options] <command> [args...]`
- Run a command and return its stdout.
- Options:
  - `--env KEY=VALUE` — Inject environment variables into the launched command.
  - `--allow-remote-control` — Allow remote-control in the launched child if supported.
  - `--remote-control-password password` — Set the remote-control password for the child.
- Arguments: <command> [args...]
- Output:
  - Prints the child command stdout when available.

### `scroll-window`

- Summary: Scroll a window by amount or to an endpoint.
- Synopsis: `jterm @ scroll-window [options] <amount|start|end>`
- Scroll a window by line count or jump to start/end.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--no-response` — Suppress the response body for this invocation.
- Arguments: <amount|start|end>
- Output:
  - Silent by default unless `--response` is set.

### `select-window`

- Summary: Interactive focus flow for choosing a window.
- Synopsis: `jterm @ select-window [options]`
- Interactive select-style focus flow. If only one target matches, it focuses immediately.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--response-timeout seconds` — Set a response timeout hint for interactive commands.
  - `--self` — Scope the command to the current terminal context when supported.
  - `--title text` — Override the selection UI title.
  - `--exclude-active` — Exclude the active window from the selection list.
  - `--reactivate-prev-tab` — Return focus to the previous tab after selection when supported.
- Output:
  - Prints `1` when focus was transferred.

### `send-key`

- Summary: Send one or more literal key presses.
- Synopsis: `jterm @ send-key [routing options] <key> [key ...]`
- Send one or more literal key presses such as enter, escape, or ctrl+c.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
  - `--all`, `-a` — Apply the command to every matching target.
  - `--exclude-active` — Skip the active target when broadcasting.
- Arguments: <key> [key ...]
- Output:
  - Silent by default unless `--response` is set.

### `send-text`

- Summary: Send text without synthesizing Enter unless requested.
- Synopsis: `jterm @ send-text [routing options] [text options] <text>`
- Send text to the matched target.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
  - `--all`, `-a` — Apply the command to every matching target.
  - `--exclude-active` — Skip the active target when broadcasting.
  - `--stdin` — Read the text payload from stdin.
  - `--from-file path` — Read the text payload from a file.
  - `--bracketed-paste disable|enable` — Control bracketed-paste wrapping for the payload.
  - `--submit none|enter|assistant` — Optionally submit after sending text.
- Arguments: <text>
- Output:
  - Silent by default unless `--response` is set.
- Notes:
  - Use `send-line` when the user intent is to submit text. Do not embed literal `\n` or `\r` for assistant TUIs.

### `set-background-image`

- Summary: Set a background image on matching windows.
- Synopsis: `jterm @ set-background-image [options] <path>`
- Set a background image on matching windows.
- Options:
  - `--all`, `-a` — Apply the command to every matching target.
  - `--configured`, `-c` — Use configured defaults where applicable.
  - `--layout configured|tiled|centered|scaled` — Choose the background image layout.
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--no-response` — Suppress the response body for this invocation.
- Arguments: <path>
- Output:
  - Silent by default unless `--response` is set.

### `set-background-opacity`

- Summary: Set or toggle background opacity.
- Synopsis: `jterm @ set-background-opacity [options] <opacity>`
- Set or toggle background opacity.
- Options:
  - `--all`, `-a` — Apply the command to every matching target.
  - `--toggle` — Toggle the current opacity override.
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
- Arguments: <opacity>
- Output:
  - Silent by default unless `--response` is set.

### `set-colors`

- Summary: Apply color overrides.
- Synopsis: `jterm @ set-colors [options] KEY=VALUE [KEY=VALUE ...]`
- Apply color overrides such as `foreground=#ffffff`.
- Options:
  - `--all`, `-a` — Apply the command to every matching target.
  - `--configured`, `-c` — Use configured defaults where applicable.
  - `--reset` — Reset the color override state.
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
- Arguments: KEY=VALUE [KEY=VALUE ...]
- Output:
  - Silent by default unless `--response` is set.

### `set-enabled-layouts`

- Summary: Set the enabled layout list.
- Synopsis: `jterm @ set-enabled-layouts [options] <layout1,layout2,...>`
- Set the enabled layouts list on matching windows.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--configured`, `-c` — Use configured defaults where applicable.
- Arguments: <layout1,layout2,...>
- Output:
  - Silent by default unless `--response` is set.

### `set-font-size`

- Summary: Set the font size override.
- Synopsis: `jterm @ set-font-size [options] <points>`
- Set the font size override.
- Options:
  - `--all`, `-a` — Apply the command to every matching target.
- Arguments: <points>
- Output:
  - Silent by default unless `--response` is set.

### `set-spacing`

- Summary: Set spacing or padding overrides.
- Synopsis: `jterm @ set-spacing [options] <key=value> [key=value ...]`
- Set spacing or padding overrides such as `padding=10`.
- Options:
  - `--all`, `-a` — Apply the command to every matching target.
  - `--configured`, `-c` — Use configured defaults where applicable.
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
- Arguments: <key=value> [key=value ...]
- Output:
  - Silent by default unless `--response` is set.

### `set-tab-color`

- Summary: Set tab colors on the matched tab.
- Synopsis: `jterm @ set-tab-color [options] <color-or-key=value> [more...]`
- Set tab colors on the matched tab.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--self` — Scope the command to the current terminal context when supported.
- Arguments: <color-or-key=value> [more...]
- Output:
  - Silent by default unless `--response` is set.

### `set-tab-title`

- Summary: Set the title of the matching tab.
- Synopsis: `jterm @ set-tab-title [options] <title>`
- Set the title of the matching tab.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
- Arguments: <title>
- Output:
  - Silent by default unless `--response` is set.

### `set-user-vars`

- Summary: Set user variables for later matching.
- Synopsis: `jterm @ set-user-vars --match <expr> KEY=VALUE [KEY=VALUE ...]`
- Set user variables for later matching or metadata.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
- Arguments: KEY=VALUE [KEY=VALUE ...]
- Output:
  - Silent by default unless `--response` is set.

### `set-window-logo`

- Summary: Set a window logo image.
- Synopsis: `jterm @ set-window-logo [options] <path>`
- Set a window logo image.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--self` — Scope the command to the current terminal context when supported.
  - `--position corner` — Place the logo in a specific corner or anchor.
  - `--alpha 0..1` — Set the logo alpha.
  - `--no-response` — Suppress the response body for this invocation.
- Arguments: <path>
- Output:
  - Silent by default unless `--response` is set.

### `set-window-title`

- Summary: Set the title of the matching window.
- Synopsis: `jterm @ set-window-title [options] <title>`
- Set the title of the matching window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--temporary` — Set a temporary title that may later be replaced by app state.
- Arguments: <title>
- Output:
  - Silent by default unless `--response` is set.

### `signal-child`

- Summary: Send a signal to a child process.
- Synopsis: `jterm @ signal-child --match <expr> <signal>`
- Send a signal such as `SIGTERM` to the child process of the target window.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--no-response` — Suppress the response body for this invocation.
- Arguments: <signal>
- Output:
  - Silent by default unless `--response` is set.

### `send-line`

- Summary: Send text and then press Enter.
- Synopsis: `jterm @ send-line [routing options] <text>`
- Alias of: `send-text + send-key enter`
- Submit one line of text by sending text and then Enter.
- Recommended for shell commands and assistant TUIs such as Claude Code or Codex.
- Options:
  - `--match expr`, `-m expr` — Target windows or surfaces matching the expression.
  - `--match-tab expr`, `-t expr` — Target tabs matching the expression.
  - `--all`, `-a` — Apply the command to every matching target.
  - `--exclude-active` — Skip the active target when broadcasting.
- Arguments: <text>
- Output:
  - Silent by default unless `--response` is set.
- Examples:
  - `jterm @ send-line --match "id:5" "pwd"`
  - `jterm @ send-line --match "id:5" "Who was the 34th president?"`
- Notes:
  - Equivalent to `send-text` followed by `send-key enter`.
  - Use this when the intent is to submit, rather than pasting literal newlines.


## SEE ALSO

- `docs/JTERM_REMOTE_CONTROL_USER_GUIDE.md`
- `docs/REMOTE_CONTROL_MANPAGE_GRADE_PLAN.md`
