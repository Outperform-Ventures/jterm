#!/usr/bin/env python3
"""CLI help/option parity checks against kitty spec lock."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

OPT_RE = re.compile(r"--[a-z0-9][a-z0-9-]*")


def default_jterm_bin() -> str:
    return "zig-out/bin/jterm"


def run_cmd(args: list[str], timeout: float = 8.0) -> tuple[int, str, str]:
    proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


def expected_long_options(option_spec: str) -> list[str]:
    return sorted(set(OPT_RE.findall(option_spec)))


def check_global_help(kitten_bin: str, jterm_bin: str) -> list[str]:
    errors: list[str] = []

    k_rc, k_out, k_err = run_cmd([kitten_bin, "@", "--help"])
    j_rc, j_out, j_err = run_cmd([jterm_bin, "@", "--help"])

    if k_rc != 0:
        errors.append(f"kitty global help failed rc={k_rc} stderr={k_err.strip()!r}")
    if j_rc != k_rc:
        errors.append(f"jterm global help rc mismatch kitty={k_rc} jterm={j_rc}")

    k_text = k_out + "\n" + k_err
    j_text = j_out + "\n" + j_err

    for needle in ("Commands:", "Global options:"):
        if needle not in k_text:
            errors.append(f"kitty global help missing section: {needle!r}")
        if needle not in j_text:
            errors.append(f"jterm global help missing section: {needle!r}")

    return errors


def check_command_help(
    kitten_bin: str,
    jterm_bin: str,
    cmd: str,
    options: list[str],
) -> list[str]:
    errors: list[str] = []

    k_rc, k_out, k_err = run_cmd([kitten_bin, "@", cmd, "--help"])
    j_rc, j_out, j_err = run_cmd([jterm_bin, "@", cmd, "--help"])

    if k_rc != 0:
        errors.append(f"{cmd}: kitty help failed rc={k_rc} stderr={k_err.strip()!r}")
        return errors

    if j_rc != k_rc:
        errors.append(f"{cmd}: help rc mismatch kitty={k_rc} jterm={j_rc}")

    k_text = k_out + "\n" + k_err
    j_text = j_out + "\n" + j_err

    if "Options:" not in k_text:
        errors.append(f"{cmd}: kitty help missing 'Options:' section")

    if "Options:" not in j_text:
        errors.append(f"{cmd}: jterm help missing 'Options:' section")

    for opt_spec in options:
        for opt in expected_long_options(opt_spec):
            if opt not in k_text:
                errors.append(f"{cmd}: kitty help missing expected option token {opt!r}")
            if opt not in j_text:
                errors.append(f"{cmd}: jterm help missing expected option token {opt!r}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", default="docs/KITTY_0_45_0_SPEC_LOCK.json")
    parser.add_argument("--kitten-bin", default="/Applications/kitty.app/Contents/MacOS/kitten")
    parser.add_argument("--jterm-bin", default=default_jterm_bin())
    parser.add_argument("--max-errors", type=int, default=200)
    args = parser.parse_args()

    spec: dict[str, Any] = json.loads(Path(args.spec).read_text(encoding="utf-8"))
    errors: list[str] = []

    errors.extend(check_global_help(args.kitten_bin, args.jterm_bin))

    for cmd_info in spec.get("commands", []):
        cmd_name = str(cmd_info.get("name"))
        cmd_opts = [str(v) for v in cmd_info.get("options", [])]
        errors.extend(check_command_help(args.kitten_bin, args.jterm_bin, cmd_name, cmd_opts))
        if len(errors) >= args.max_errors:
            break

    if errors:
        print(f"CLI parity check failed: {len(errors)} issue(s)")
        for err in errors[: args.max_errors]:
            print(f"  - {err}")
        if len(errors) > args.max_errors:
            print(f"  ... {len(errors) - args.max_errors} more")
        return 1

    print("CLI parity check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
