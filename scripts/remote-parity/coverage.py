#!/usr/bin/env python3
"""Initialize and verify kitty parity coverage tracking."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

PHASE_RANGE = list(range(0, 11))
STATUS_VALUES = {"pending", "in_progress", "complete"}

COMMAND_PHASE = {
    "action": 5,
    "close-tab": 4,
    "close-window": 4,
    "create-marker": 6,
    "detach-tab": 4,
    "detach-window": 4,
    "disable-ligatures": 7,
    "env": 6,
    "focus-tab": 4,
    "focus-window": 4,
    "get-colors": 7,
    "get-text": 7,
    "goto-layout": 4,
    "kitten": 5,
    "last-used-layout": 4,
    "launch": 3,
    "load-config": 8,
    "ls": 2,
    "new-window": 3,
    "remove-marker": 6,
    "resize-os-window": 4,
    "resize-window": 4,
    "run": 5,
    "scroll-window": 5,
    "select-window": 4,
    "send-key": 5,
    "send-text": 5,
    "set-background-image": 7,
    "set-background-opacity": 7,
    "set-colors": 7,
    "set-enabled-layouts": 4,
    "set-font-size": 7,
    "set-spacing": 7,
    "set-tab-color": 6,
    "set-tab-title": 6,
    "set-user-vars": 6,
    "set-window-logo": 6,
    "set-window-title": 6,
    "signal-child": 8,
}


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def status_or_pending(value: Any) -> str:
    if isinstance(value, str) and value in STATUS_VALUES:
        return value
    return "pending"


def init_coverage(spec_path: Path, output_path: Path, merge: bool) -> int:
    spec = load_json(spec_path)
    prev: dict[str, Any] = {}
    if merge and output_path.exists():
        prev_raw = load_json(output_path)
        if isinstance(prev_raw, dict):
            prev = prev_raw

    prev_phases = prev.get("phases", {}) if isinstance(prev.get("phases"), dict) else {}
    prev_commands = prev.get("commands", {}) if isinstance(prev.get("commands"), dict) else {}

    phases: dict[str, str] = {}
    for phase in PHASE_RANGE:
        phases[str(phase)] = status_or_pending(prev_phases.get(str(phase)))

    commands: dict[str, Any] = {}
    for cmd in spec.get("commands", []):
        name = cmd["name"]
        prev_cmd = prev_commands.get(name, {}) if isinstance(prev_commands.get(name), dict) else {}
        prev_options = prev_cmd.get("options", {}) if isinstance(prev_cmd.get("options"), dict) else {}

        options: dict[str, str] = {}
        for opt in cmd.get("options", []):
            options[opt] = status_or_pending(prev_options.get(opt))

        commands[name] = {
            "phase": COMMAND_PHASE.get(name),
            "status": status_or_pending(prev_cmd.get("status")),
            "options": options,
        }

    out = {
        "kitty_version": spec.get("kitty_version"),
        "command_count": spec.get("command_count"),
        "command_option_count_total": spec.get("command_option_count_total"),
        "phases": phases,
        "commands": commands,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote coverage skeleton: {output_path}")
    return 0


def check_coverage(path: Path, require_complete: bool) -> int:
    cov = load_json(path)

    phases = cov.get("phases", {})
    commands = cov.get("commands", {})

    phase_total = len(phases)
    phase_complete = sum(1 for v in phases.values() if v == "complete")

    cmd_total = len(commands)
    cmd_complete = 0
    opt_total = 0
    opt_complete = 0

    for cmd_data in commands.values():
        if not isinstance(cmd_data, dict):
            continue
        if cmd_data.get("status") == "complete":
            cmd_complete += 1
        opts = cmd_data.get("options", {})
        if isinstance(opts, dict):
            for status in opts.values():
                opt_total += 1
                if status == "complete":
                    opt_complete += 1

    print(
        "Coverage summary: "
        f"phases={phase_complete}/{phase_total} "
        f"commands={cmd_complete}/{cmd_total} "
        f"options={opt_complete}/{opt_total}"
    )

    if require_complete:
        if phase_complete != phase_total:
            print("Coverage gate failed: not all phases are complete")
            return 1
        if cmd_complete != cmd_total:
            print("Coverage gate failed: not all commands are complete")
            return 1
        if opt_complete != opt_total:
            print("Coverage gate failed: not all options are complete")
            return 1

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    init_p = sub.add_parser("init", help="Initialize or refresh coverage file")
    init_p.add_argument("--spec", default="docs/KITTY_0_45_0_SPEC_LOCK.json")
    init_p.add_argument("--output", default="docs/KITTY_PARITY_COVERAGE.json")
    init_p.add_argument("--merge", action="store_true")

    chk_p = sub.add_parser("check", help="Check coverage completeness")
    chk_p.add_argument("--input", default="docs/KITTY_PARITY_COVERAGE.json")
    chk_p.add_argument("--require-complete", action="store_true")

    args = parser.parse_args()

    if args.cmd == "init":
        return init_coverage(Path(args.spec), Path(args.output), args.merge)
    if args.cmd == "check":
        return check_coverage(Path(args.input), args.require_complete)

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
