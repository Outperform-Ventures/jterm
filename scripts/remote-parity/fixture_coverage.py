#!/usr/bin/env python3
"""Validate phase fixture coverage across commands and phases."""

from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path
from typing import Any

EXPECTED_PHASES = set(range(0, 11))


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def extract_command(op: dict[str, Any]) -> str | None:
    args = op.get("args", [])
    if not isinstance(args, list) or not args:
        return None
    first = args[0]
    if not isinstance(first, str):
        return None
    return first


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", default="docs/KITTY_0_45_0_SPEC_LOCK.json")
    parser.add_argument("--phases-dir", default="test/remote/parity/phases")
    args = parser.parse_args()

    spec = load_json(args.spec)
    expected_commands = {str(cmd["name"]) for cmd in spec.get("commands", [])}

    fixture_paths = sorted(glob.glob(str(Path(args.phases_dir) / "**" / "*.json"), recursive=True))
    if not fixture_paths:
        print("No phase fixtures found")
        return 1

    seen_phases: set[int] = set()
    seen_commands: set[str] = set()

    errors: list[str] = []

    for path in fixture_paths:
        data = load_json(path)
        phase = data.get("phase")
        if not isinstance(phase, int):
            errors.append(f"{path}: missing integer 'phase' field")
        else:
            seen_phases.add(phase)

        ops = data.get("operations", [])
        if not isinstance(ops, list) or not ops:
            errors.append(f"{path}: no operations")
            continue

        for op in ops:
            if not isinstance(op, dict):
                errors.append(f"{path}: operation is not an object")
                continue
            cmd = extract_command(op)
            if cmd:
                seen_commands.add(cmd)

    missing_phases = sorted(EXPECTED_PHASES - seen_phases)
    if missing_phases:
        errors.append(f"missing phase fixtures for phases: {missing_phases}")

    missing_commands = sorted(expected_commands - seen_commands)
    if missing_commands:
        errors.append(
            "phase fixtures do not exercise commands: " + ", ".join(missing_commands)
        )

    if errors:
        print(f"Fixture coverage check failed: {len(errors)} issue(s)")
        for err in errors:
            print(f"  - {err}")
        return 1

    print(
        f"Fixture coverage passed: phases={len(seen_phases)}/11 "
        f"commands={len(seen_commands)}/{len(expected_commands)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
