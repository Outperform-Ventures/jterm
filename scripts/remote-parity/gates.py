#!/usr/bin/env python3
"""Run full parity gates for phases 0-10."""

from __future__ import annotations

import argparse
import shlex
import subprocess
from dataclasses import dataclass


@dataclass
class Step:
    name: str
    cmd: list[str]


def run_step(step: Step) -> int:
    print(f"\n==> {step.name}")
    print("$ " + " ".join(shlex.quote(part) for part in step.cmd))
    proc = subprocess.run(step.cmd)
    if proc.returncode != 0:
        print(f"Step failed: {step.name} (rc={proc.returncode})")
    else:
        print(f"Step passed: {step.name}")
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default="python3")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-zig-tests", action="store_true")
    parser.add_argument("--allow-incomplete-coverage", action="store_true")
    parser.add_argument("--no-spawn-apps", action="store_true")
    parser.add_argument("--fail-fast", action="store_true")
    args = parser.parse_args()

    py = args.python

    steps: list[Step] = [
        Step(
            "Initialize Coverage Tracker",
            [
                py,
                "scripts/remote-parity/coverage.py",
                "init",
                "--spec",
                "docs/KITTY_0_45_0_SPEC_LOCK.json",
                "--output",
                "docs/KITTY_PARITY_COVERAGE.json",
                "--merge",
            ],
        ),
        Step("Validate Crypto Vectors", [py, "scripts/remote-parity/validate_vectors.py"]),
        Step("Phase Fixture Coverage", [py, "scripts/remote-parity/fixture_coverage.py"]),
        Step("Protocol Parity", [py, "scripts/remote-parity/protocol_parity.py"]),
        Step("CLI Parity", [py, "scripts/remote-parity/cli_parity.py"]),
        Step(
            "Behavioral Parity (fixtures+corpus+phases)",
            [
                py,
                "scripts/remote-parity/certify.py",
                "--mode",
                "all",
                "--strict-known-gaps",
                *([] if args.no_spawn_apps else ["--spawn-apps"]),
            ],
        ),
    ]

    if not args.skip_build:
        steps.append(Step("Build", ["zig", "build"]))
    if not args.skip_zig_tests:
        steps.append(Step("Zig Tests", ["zig", "build", "test"]))

    coverage_check = [py, "scripts/remote-parity/coverage.py", "check", "--input", "docs/KITTY_PARITY_COVERAGE.json"]
    if not args.allow_incomplete_coverage:
        coverage_check.append("--require-complete")
    steps.append(Step("Coverage Gate", coverage_check))

    failures: list[tuple[str, int]] = []
    for step in steps:
        rc = run_step(step)
        if rc != 0:
            failures.append((step.name, rc))
            if args.fail_fast:
                break

    if failures:
        print("\nParity gates failed:")
        for name, rc in failures:
            print(f"  - {name} (rc={rc})")
        return 1

    print("\nAll parity gates passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
