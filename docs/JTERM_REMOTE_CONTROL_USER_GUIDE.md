# jTerm Remote Control User Guide

Last updated: 2026-02-22
Target baseline: kitty remote-control spec lock `0.45.0` + jTerm extensions

Generated command references:

- [JTERM_REMOTE_CONTROL_COMMAND_REFERENCE.md](/Users/jkuechly/code/jterm/docs/JTERM_REMOTE_CONTROL_COMMAND_REFERENCE.md)
- [JTERM_REMOTE_CONTROL_CLI_MANPAGE.md](/Users/jkuechly/code/jterm/docs/JTERM_REMOTE_CONTROL_CLI_MANPAGE.md)

The generated reference and manpage docs are the source of truth for command syntax, options, output behavior, and exit codes. This guide remains the narrative overview and workflow guide.

## What jTerm Remote Control Is

jTerm remote control lets you script and control a running jTerm app from the command line.

You use:

```bash
jterm @ <command> [flags] [args]
```

Examples:

```bash
jterm @ ls
jterm @ new-window
jterm @ new-tab
jterm @ set-window-title "Build Logs"
jterm @ send-text "echo hello"
```

This is useful for automation, launchers, webapps, scripts, and workflow tools that need to open/focus/rename/send commands to terminals.

## How It Works

At a high level:

1. `jterm @ ...` parses your command and options.
2. jTerm CLI builds a JSON request (kitty-style envelope).
3. The request is sent over a local Unix socket (`unix:/...`).
4. The running jTerm app validates/authenticates the request.
5. jTerm executes the action and returns JSON (or no output if configured/flagged silent).

Transport details:

- Local Unix sockets only (`unix:/path`)
- Default socket:
  - debug/dev builds: `unix:/tmp/jterm-dev.sock`
  - release/stable builds: `unix:/tmp/jterm-stable.sock`
- Socket file permissions are restricted to owner mode where possible.

## Requirements

- jTerm app must be running.
- Remote control must be enabled in config.
- `jterm` CLI must be in your `PATH`.

## Quick Start (First-Time Setup)

### 1) Enable remote control in config

Add these lines to your jTerm config:

```ini
allow-remote-control = true
remote-control-default-no-response = true
# optional:
# remote-control-password = "your-secret"
```

Notes:

- `allow-remote-control`: starts the listener.
- `remote-control-default-no-response`: makes commands silent by default.
- `remote-control-password`: optional shared secret.

### 2) Launch jTerm app

```bash
open -na /Applications/jTerm.app
```

### 3) Test command

```bash
jterm @ ls
```

If everything is configured, this prints JSON describing current jTerm windows/tabs.

## Where Config Lives

On macOS, jTerm uses the bundle id `com.jterm.app`. The app-support config file is under:

- `~/Library/Application Support/com.jterm.app/config`

Legacy/XDG paths may also be detected when present.

Useful helper actions:

```bash
jterm +edit-config
jterm +show-config --default --docs
```

## Command Syntax

### Primary form

```bash
jterm @ [global options] <command> [command options] [command args]
```

### Alias form

```bash
jterm +remote-control [global options] <command> ...
```

## Global Options

These apply to all remote-control commands.

- `--to=unix:/path.sock`
- `--password=...`
- `--password-file=...`
- `--password-env=ENV_NAME`
- `--use-password=if-available|always|never`
- `--help` / `-h`

jTerm-specific response control:

- `--response`: force output body printing
- `--no-response`: force silent request

Targeting helpers (accepted across commands):

- `--match=...`
- `--match-tab=...`
- `--all`
- `--ignore-no-match`
- `--response-timeout=SECONDS`

## Listener and Socket Target

Default target is:

- `unix:/tmp/jterm-dev.sock` for debug/dev builds
- `unix:/tmp/jterm-stable.sock` for release/stable builds

Override target for app and CLI with environment variable:

```bash
export JTERM_LISTEN_ON=unix:/tmp/jterm-custom.sock
```

Then start app and run commands using same target (explicitly or by env fallback):

```bash
open -na /Applications/jTerm.app
jterm @ --to=unix:/tmp/jterm-custom.sock ls
```

## Authentication and Security

### Password mode

If `remote-control-password` is set, requests must provide matching password data.

Common forms:

```bash
jterm @ --password='secret' ls
jterm @ --password-file=/path/to/pass.txt ls
jterm @ --password-env=JTERM_RC_PASSWORD ls
```

### Encrypted request path for password-authenticated requests

When password transport is active, jTerm expects encrypted request envelopes and requires a public key in env:

- `KITTY_PUBLIC_KEY` (preferred)
- `JTERM_PUBLIC_KEY` (fallback)

Practical flow:

```bash
# needs jq installed
export KITTY_PUBLIC_KEY="$(jterm @ ls --all-env-vars | jq -r '.kitty_public_key')"
export JTERM_RC_PASSWORD='secret'
jterm @ --password-env=JTERM_RC_PASSWORD set-window-title "secure-title"
```

If you see `Remote-control password mode requires KITTY_PUBLIC_KEY.`, set the key env variable first.

## Target Matching

Use `--match` and `--match-tab` to select targets.

Expression model:

- `,` means AND
- `||` means OR

Supported keys:

- `id:<n>`
- `pid:<n>`
- `num:<n>`
- `title:<text>`
- `cmdline:<text>`
- `cwd:<text>`
- `session:<text>`
- `neighbor:<text>`
- `state:focused|unfocused|active|inactive`
- `recent:<n>`
- `env:KEY=PATTERN`
- `var:KEY=PATTERN`

Pattern behavior for `env:` / `var:`:

- `^...$` exact match
- `^...` prefix match
- `...$` suffix match
- otherwise substring match

Examples:

```bash
jterm @ focus-window --match id:3
jterm @ focus-window --match "env:SYMPH_WINDOW=^build$"
jterm @ send-text --match "title:worker,cwd:/repo" "npm test"
jterm @ close-window --match "id:999" --ignore-no-match
```

## Output Behavior

jTerm returns JSON responses from the app, then the CLI formats output for convenience.

Important defaults:

- Many mutating commands are silent unless `--response` is used.
- Query-style commands print output by default.
- `remote-control-default-no-response=true` makes everything silent unless overridden.

Typical output behavior:

- `ls`: JSON object
- `new-window` / `new-tab` / `launch`: created id or success
- `run`: stdout content when run out-of-surface, success response otherwise
- `get-text`: text
- `get-colors`: colors text/list
- `select-window`: focused indicator

## Everyday Examples

### List windows/tabs

```bash
jterm @ ls
```

### Open a new window and a new tab

```bash
jterm @ new-window
jterm @ new-tab
```

### Rename window and tab independently

```bash
jterm @ set-window-title "Backend"
jterm @ set-tab-title "Logs"
```

### Send command text to selected window

```bash
jterm @ send-text --match "title:Backend" "echo it works"
```

### Launch a workflow window with env tag

```bash
jterm @ launch --type=os-window --title="symph: demo" --env=SYMPH_WINDOW=demo bash -lc "symph me demo"
```

### Focus previously tagged window

```bash
jterm @ focus-window --match "env:SYMPH_WINDOW=^demo$"
```

### Close safely (ignore missing target)

```bash
jterm @ close-window --match "env:SYMPH_WINDOW=^demo$" --ignore-no-match
```

## Command Catalog (What You Can Run)

- `action`: run an action/binding on target
- `close-tab`: close tab(s)
- `close-window`: close window(s)
- `create-marker`: create marker(s)
- `detach-tab`: detach tab
- `detach-window`: detach window
- `disable-ligatures`: toggle ligatures policy
- `env`: set/unset/query env metadata
- `focus-tab`: focus tab
- `focus-window`: focus window
- `get-colors`: query colors
- `get-text`: query text
- `goto-layout`: change layout
- `kitten`: kitten-style invocation
- `last-used-layout`: restore previous layout
- `launch`: launch new terminal process/window
- `load-config`: reload config
- `ls`: list runtime graph (windows/tabs)
- `new-tab`: create tab (jTerm extension/alias)
- `new-window`: create window
- `remove-marker`: remove markers
- `resize-os-window`: resize host window
- `resize-window`: resize terminal split/window
- `run`: run command
- `scroll-window`: scroll target
- `select-window`: interactive/select-style focus flow
- `send-key`: send key sequence
- `send-text`: send text
- `set-background-image`: set background image
- `set-background-opacity`: set/toggle opacity
- `set-colors`: apply colors
- `set-enabled-layouts`: set enabled layouts
- `set-font-size`: adjust font size
- `set-spacing`: set spacing/padding
- `set-tab-color`: set tab colors
- `set-tab-title`: set tab title
- `set-user-vars`: set user vars
- `set-window-logo`: set window logo
- `set-window-title`: set window title
- `signal-child`: signal child process

## Complete Command + Flag Reference

Reference basis:

- `docs/KITTY_0_45_0_SPEC_LOCK.json`
- `src/remote/command.zig`

### `action`
- Options:
  - `--self [=no]`
  - `--no-response [=no]`
  - `--match, -m`
  - `--help, -h [=no]`

### `close-tab`
- Options:
  - `--match, -m`
  - `--no-response [=no]`
  - `--self [=no]`
  - `--ignore-no-match [=no]`
  - `--help, -h [=no]`

### `close-window`
- Options:
  - `--match, -m`
  - `--no-response [=no]`
  - `--self [=no]`
  - `--ignore-no-match [=no]`
  - `--help, -h [=no]`

### `create-marker`
- Options:
  - `--match, -m`
  - `--self [=no]`
  - `--help, -h [=no]`

### `detach-tab`
- Options:
  - `--match, -m`
  - `--target-tab, -t`
  - `--self [=no]`
  - `--help, -h [=no]`

### `detach-window`
- Options:
  - `--match, -m`
  - `--target-tab, -t`
  - `--self [=no]`
  - `--stay-in-tab [=no]`
  - `--help, -h [=no]`

### `disable-ligatures`
- Options:
  - `--all, -a [=no]`
  - `--match, -m`
  - `--match-tab, -t`
  - `--help, -h [=no]`

### `env`
- Options:
  - `--help, -h [=no]`

### `focus-tab`
- Options:
  - `--match, -m`
  - `--no-response [=no]`
  - `--help, -h [=no]`

### `focus-window`
- Options:
  - `--match, -m`
  - `--no-response [=no]`
  - `--help, -h [=no]`

### `get-colors`
- Options:
  - `--configured, -c [=no]`
  - `--match, -m`
  - `--help, -h [=no]`

### `get-text`
- Options:
  - `--match, -m`
  - `--extent [=screen]`
  - `--ansi [=no]`
  - `--add-cursor [=no]`
  - `--add-wrap-markers [=no]`
  - `--clear-selection [=no]`
  - `--self [=no]`
  - `--help, -h [=no]`

### `goto-layout`
- Options:
  - `--match, -m`
  - `--help, -h [=no]`

### `kitten`
- Options:
  - `--match, -m`
  - `--help, -h [=no]`

### `last-used-layout`
- Options:
  - `--all, -a [=no]`
  - `--no-response [=no]`
  - `--match, -m`
  - `--help, -h [=no]`

### `launch`
- Options:
  - `--match, -m`
  - `--wait-for-child-to-exit [=no]`
  - `--response-timeout [=86400]`
  - `--no-response [=no]`
  - `--self [=no]`
  - `--source-window`
  - `--title, --window-title`
  - `--tab-title`
  - `--type [=window]`
  - `--dont-take-focus, --keep-focus [=no]`
  - `--cwd`
  - `--add-to-session`
  - `--env`
  - `--var`
  - `--hold [=no]`
  - `--copy-colors [=no]`
  - `--copy-cmdline [=no]`
  - `--copy-env [=no]`
  - `--location [=default]`
  - `--next-to`
  - `--bias [=0]`
  - `--allow-remote-control [=no]`
  - `--remote-control-password`
  - `--stdin-source [=none]`
  - `--stdin-add-formatting [=no]`
  - `--stdin-add-line-wrap-markers [=no]`
  - `--marker`
  - `--os-window-class`
  - `--os-window-name`
  - `--os-window-title`
  - `--os-window-state [=normal]`
  - `--logo`
  - `--logo-position`
  - `--logo-alpha [=-1]`
  - `--color`
  - `--spacing`
  - `--watcher, -w`
  - `--os-panel`
  - `--hold-after-ssh [=no]`
  - `--help, -h [=no]`

### `load-config`
- Options:
  - `--ignore-overrides [=no]`
  - `--override, -o`
  - `--no-response [=no]`
  - `--help, -h [=no]`

### `ls`
- Options:
  - `--all-env-vars [=no]`
  - `--self [=no]`
  - `--output-format [=json]`
  - `--match, -m`
  - `--match-tab, -t`
  - `--help, -h [=no]`

### `new-tab` (jTerm extension)
- Options:
  - `--match, -m`
  - `--match-tab, -t`
  - `--all [=no]`
  - `--ignore-no-match [=no]`
  - `--no-response [=no]`
  - `--response-timeout`
  - `--help, -h [=no]`

### `new-window`
- Options:
  - `--match, -m`
  - `--title`
  - `--cwd`
  - `--dont-take-focus, --keep-focus [=no]`
  - `--window-type [=kitty]`
  - `--new-tab [=no]`
  - `--tab-title`
  - `--no-response [=no]`
  - `--help, -h [=no]`

### `remove-marker`
- Options:
  - `--match, -m`
  - `--self [=no]`
  - `--help, -h [=no]`

### `resize-os-window`
- Options:
  - `--match, -m`
  - `--action [=resize]`
  - `--unit [=cells]`
  - `--width [=0]`
  - `--height [=0]`
  - `--incremental [=no]`
  - `--self [=no]`
  - `--no-response [=no]`
  - `--help, -h [=no]`

### `resize-window`
- Options:
  - `--match, -m`
  - `--increment, -i [=2]`
  - `--axis, -a [=horizontal]`
  - `--self [=no]`
  - `--help, -h [=no]`

### `run`
- Options:
  - `--env`
  - `--allow-remote-control [=no]`
  - `--remote-control-password`
  - `--help, -h [=no]`

### `scroll-window`
- Options:
  - `--match, -m`
  - `--no-response [=no]`
  - `--help, -h [=no]`

### `select-window`
- Options:
  - `--match, -m`
  - `--response-timeout [=60]`
  - `--self [=no]`
  - `--title`
  - `--exclude-active [=no]`
  - `--reactivate-prev-tab [=no]`
  - `--help, -h [=no]`

### `send-key`
- Options:
  - `--match, -m`
  - `--match-tab, -t`
  - `--all [=no]`
  - `--exclude-active [=no]`
  - `--help, -h [=no]`

### `send-text`
- Options:
  - `--match, -m`
  - `--match-tab, -t`
  - `--all [=no]`
  - `--exclude-active [=no]`
  - `--stdin [=no]`
  - `--from-file`
  - `--bracketed-paste [=disable]`
  - `--help, -h [=no]`

### `set-background-image`
- Options:
  - `--all, -a [=no]`
  - `--configured, -c [=no]`
  - `--layout [=configured]`
  - `--no-response [=no]`
  - `--match, -m`
  - `--help, -h [=no]`

### `set-background-opacity`
- Options:
  - `--all, -a [=no]`
  - `--toggle [=no]`
  - `--match, -m`
  - `--match-tab, -t`
  - `--help, -h [=no]`

### `set-colors`
- Options:
  - `--all, -a [=no]`
  - `--configured, -c [=no]`
  - `--reset [=no]`
  - `--match, -m`
  - `--match-tab, -t`
  - `--help, -h [=no]`

### `set-enabled-layouts`
- Options:
  - `--match, -m`
  - `--configured [=no]`
  - `--help, -h [=no]`

### `set-font-size`
- Options:
  - `--all, -a [=no]`
  - `--help, -h [=no]`

### `set-spacing`
- Options:
  - `--all, -a [=no]`
  - `--configured, -c [=no]`
  - `--match, -m`
  - `--match-tab, -t`
  - `--help, -h [=no]`

### `set-tab-color`
- Options:
  - `--match, -m`
  - `--self [=no]`
  - `--help, -h [=no]`

### `set-tab-title`
- Options:
  - `--match, -m`
  - `--help, -h [=no]`

### `set-user-vars`
- Options:
  - `--match, -m`
  - `--help, -h [=no]`

### `set-window-logo`
- Options:
  - `--match, -m`
  - `--self [=no]`
  - `--position`
  - `--alpha [=-1]`
  - `--no-response [=no]`
  - `--help, -h [=no]`

### `set-window-title`
- Options:
  - `--temporary [=no]`
  - `--match, -m`
  - `--help, -h [=no]`

### `signal-child`
- Options:
  - `--no-response [=no]`
  - `--match, -m`
  - `--help, -h [=no]`

## Troubleshooting

### `Remote-control transport failure: error.FileNotFound`

The socket path does not exist. Usually means jTerm app is not running with remote control enabled or target path mismatch.

Check:

```bash
open -na /Applications/jTerm.app
jterm @ ls
```

Or specify explicit target:

```bash
jterm @ --to=unix:/tmp/jterm-stable.sock ls
```

### `Remote-control transport failure: error.ConnectionRefused`

Socket exists but listener is not active (or wrong socket).

- Confirm `allow-remote-control = true`
- Restart jTerm app
- Ensure `JTERM_LISTEN_ON` matches both sides

### `Error: remote-control authorization failed`

- Password mismatch or missing password
- Password-mode encrypted request missing/invalid key env

Check:

- `remote-control-password` value
- `--password`, `--password-file`, or `--password-env`
- `KITTY_PUBLIC_KEY` / `JTERM_PUBLIC_KEY`

### `Error: invalid command arguments`

Flag/arg combination is not valid for that command.

Use:

```bash
jterm @ <command> --help
```

## Recommended Operational Defaults

For automation-heavy usage:

```ini
allow-remote-control = true
remote-control-default-no-response = true
# remote-control-password = "set-a-secret-for-local-security"
```

Then opt into output only when needed:

```bash
jterm @ --response ls
jterm @ --response get-text --match "id:1"
```
