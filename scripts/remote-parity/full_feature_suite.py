#!/usr/bin/env python3
"""Run a full remote-control feature suite for the pinned kitty spec."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import certify


@dataclass
class StepResult:
    name: str
    rc: int
    stdout: str
    stderr: str


@dataclass
class FixtureRunResult:
    passed: bool
    errors: list[str]


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def run_step(name: str, cmd: list[str]) -> StepResult:
    print(f"\n==> {name}")
    print("$ " + " ".join(shlex.quote(x) for x in cmd))
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.stdout.strip():
        print(proc.stdout.rstrip())
    if proc.stderr.strip():
        print(proc.stderr.rstrip(), file=sys.stderr)
    if proc.returncode == 0:
        print(f"Step passed: {name}")
    else:
        print(f"Step failed: {name} (rc={proc.returncode})")
    return StepResult(name=name, rc=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)


def extract_command(op: dict[str, Any]) -> str | None:
    args = op.get("args")
    if not isinstance(args, list) or not args:
        return None
    cmd = args[0]
    return cmd if isinstance(cmd, str) and cmd else None


def fixture_commands(fixture: dict[str, Any]) -> set[str]:
    cmds: set[str] = set()
    for op in fixture.get("operations", []):
        if not isinstance(op, dict):
            continue
        cmd = extract_command(op)
        if cmd:
            cmds.add(cmd)
    return cmds


def fixture_sort_key(fixture: dict[str, Any]) -> tuple[int, int, str]:
    path = str(fixture.get("_path", ""))
    src_rank = 2
    if "/fixtures/" in path:
        src_rank = 0
    elif "/corpus/" in path:
        src_rank = 1
    ops = fixture.get("operations", [])
    op_count = len(ops) if isinstance(ops, list) else 9999
    fid = str(fixture.get("id", Path(path).stem))
    return (src_rank, op_count, fid)


def choose_representative_fixtures(
    fixtures: list[dict[str, Any]],
    expected_commands: list[str],
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    by_command: dict[str, list[dict[str, Any]]] = {name: [] for name in expected_commands}
    for fixture in fixtures:
        if fixture.get("skip", False):
            continue
        if fixture.get("known_gap", False):
            continue
        for cmd in fixture_commands(fixture):
            if cmd in by_command:
                by_command[cmd].append(fixture)

    chosen: dict[str, dict[str, Any]] = {}
    missing: list[str] = []
    for cmd in expected_commands:
        candidates = by_command.get(cmd, [])
        if not candidates:
            missing.append(cmd)
            continue
        chosen[cmd] = sorted(candidates, key=fixture_sort_key)[0]
    return chosen, missing


def run_fixture(
    fixture: dict[str, Any],
    kitten_bin: str,
    kitty_target: str,
    jterm_bin: str,
    jterm_target: str,
    kitty_public_key: str | None,
    jterm_public_key: str | None,
) -> FixtureRunResult:
    errors: list[str] = []
    ops = fixture.get("operations", [])
    if not isinstance(ops, list):
        return FixtureRunResult(False, ["fixture has no operations array"])

    for idx, op in enumerate(ops):
        if not isinstance(op, dict):
            errors.append(f"op-{idx + 1}: operation entry is not an object")
            continue

        name = str(op.get("name", f"op-{idx + 1}"))
        kitty_op = dict(op)
        jterm_op = dict(op)

        if certify.op_uses_password_transport(op):
            if kitty_public_key:
                kitty_env = dict(kitty_op.get("env", {}))
                kitty_env["KITTY_PUBLIC_KEY"] = kitty_public_key
                kitty_op["env"] = kitty_env
            if jterm_public_key:
                jterm_env = dict(jterm_op.get("env", {}))
                jterm_env["KITTY_PUBLIC_KEY"] = jterm_public_key
                jterm_op["env"] = jterm_env

        kitty = certify.run_remote(kitten_bin, kitty_target, kitty_op)
        jterm = certify.run_remote(jterm_bin, jterm_target, jterm_op)

        op_errors: list[str] = []
        op_errors.extend(certify.assert_operation(f"{name}/kitty", kitty, op))
        op_errors.extend(certify.assert_operation(f"{name}/jterm", jterm, op))
        op_errors.extend(certify.compare_operation(name, kitty, jterm, op, fixture))
        errors.extend(op_errors)

    return FixtureRunResult(passed=not errors, errors=errors)


def collect_fixtures(fixtures_dir: str, corpus_dir: str, phases_dir: str) -> list[dict[str, Any]]:
    fixtures: list[dict[str, Any]] = []
    fixtures.extend(certify.load_fixtures(fixtures_dir, None))
    fixtures.extend(certify.load_fixtures(corpus_dir, None))
    fixtures.extend(certify.load_fixtures(phases_dir, None))
    return fixtures


def build_report(
    spec_path: Path,
    command_to_fixture: dict[str, dict[str, Any]],
    fixture_outcomes: dict[str, FixtureRunResult],
    gate_result: StepResult | None,
    aux_steps: list[StepResult],
) -> dict[str, Any]:
    spec = load_json(spec_path)
    commands = [str(cmd["name"]) for cmd in spec.get("commands", [])]

    command_rows: list[dict[str, Any]] = []
    failed_commands: list[str] = []
    for cmd in commands:
        fixture = command_to_fixture.get(cmd)
        if fixture is None:
            command_rows.append(
                {
                    "command": cmd,
                    "status": "missing_fixture",
                    "fixture_id": None,
                    "fixture_path": None,
                    "errors": ["no representative fixture found"],
                }
            )
            failed_commands.append(cmd)
            continue

        fid = str(fixture.get("id", Path(str(fixture.get("_path", cmd))).stem))
        outcome = fixture_outcomes.get(fid)
        if outcome is None:
            command_rows.append(
                {
                    "command": cmd,
                    "status": "not_executed",
                    "fixture_id": fid,
                    "fixture_path": fixture.get("_path"),
                    "errors": ["representative fixture was not executed"],
                }
            )
            failed_commands.append(cmd)
            continue

        status = "pass" if outcome.passed else "fail"
        if not outcome.passed:
            failed_commands.append(cmd)
        command_rows.append(
            {
                "command": cmd,
                "status": status,
                "fixture_id": fid,
                "fixture_path": fixture.get("_path"),
                "errors": outcome.errors if not outcome.passed else [],
            }
        )

    step_rows: list[dict[str, Any]] = []
    if gate_result is not None:
        step_rows.append({"name": gate_result.name, "rc": gate_result.rc})
    for step in aux_steps:
        step_rows.append({"name": step.name, "rc": step.rc})

    return {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "kitty_version": spec.get("kitty_version"),
        "command_count": len(commands),
        "steps": step_rows,
        "commands": command_rows,
        "summary": {
            "commands_passed": len(commands) - len(failed_commands),
            "commands_failed": len(failed_commands),
            "all_commands_passed": len(failed_commands) == 0,
            "gate_passed": gate_result is None or gate_result.rc == 0,
        },
    }


def print_command_summary(report: dict[str, Any]) -> None:
    print("\n==> Command Matrix")
    for row in report.get("commands", []):
        command = row.get("command")
        status = row.get("status")
        fixture_id = row.get("fixture_id")
        print(f"{status.upper():>14}  {command:<24} fixture={fixture_id}")

    summary = report.get("summary", {})
    print(
        "\nSummary: "
        f"commands_passed={summary.get('commands_passed')} "
        f"commands_failed={summary.get('commands_failed')} "
        f"gate_passed={summary.get('gate_passed')}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default="python3")
    parser.add_argument("--spec", default="docs/KITTY_0_45_0_SPEC_LOCK.json")
    parser.add_argument("--fixtures-dir", default="test/remote/parity/fixtures")
    parser.add_argument("--corpus-dir", default="test/remote/parity/corpus")
    parser.add_argument("--phases-dir", default="test/remote/parity/phases")
    parser.add_argument("--kitten-bin", default=os.environ.get("KITTEN_BIN", "/Applications/kitty.app/Contents/MacOS/kitten"))
    parser.add_argument("--kitty-bin", default=os.environ.get("KITTY_BIN", "/Applications/kitty.app/Contents/MacOS/kitty"))
    parser.add_argument("--jterm-bin", default=os.environ.get("JTERM_BIN", certify.default_jterm_bin()))
    parser.add_argument("--report-json", default="docs/KITTY_FULL_FEATURE_TEST_REPORT.json")
    parser.add_argument("--skip-gates", action="store_true")
    args = parser.parse_args()

    py = args.python
    spec_path = Path(args.spec)
    spec = load_json(spec_path)
    expected_commands = [str(cmd["name"]) for cmd in spec.get("commands", [])]

    fixtures = collect_fixtures(args.fixtures_dir, args.corpus_dir, args.phases_dir)
    command_to_fixture, missing_fixture_commands = choose_representative_fixtures(fixtures, expected_commands)

    aux_steps: list[StepResult] = []
    aux_steps.append(run_step("Validate Crypto Vectors", [py, "scripts/remote-parity/validate_vectors.py"]))
    aux_steps.append(run_step("Protocol Parity", [py, "scripts/remote-parity/protocol_parity.py"]))
    aux_steps.append(run_step("CLI Parity", [py, "scripts/remote-parity/cli_parity.py"]))
    aux_steps.append(run_step("Fixture Coverage", [py, "scripts/remote-parity/fixture_coverage.py"]))

    gate_result: StepResult | None = None
    if not args.skip_gates:
        gate_result = run_step("Parity Gates", [py, "scripts/remote-parity/gates.py"])

    pid = os.getpid()
    kitty_target = f"unix:/tmp/kitty-feature-suite-{pid}.sock"
    jterm_target = f"unix:/tmp/jterm-feature-suite-{pid}.sock"
    procs: list[subprocess.Popen[str]] = []
    fixture_outcomes: dict[str, FixtureRunResult] = {}
    default_password_file = Path("/tmp/jterm-parity-password.txt")

    try:
        default_password_file.write_text("demo\n", encoding="utf-8")

        ns = argparse.Namespace(
            kitten_bin=args.kitten_bin,
            kitty_bin=args.kitty_bin,
            jterm_bin=args.jterm_bin,
            kitty_target=kitty_target,
            jterm_target=jterm_target,
        )
        procs = certify.spawn_apps(ns)

        kitty_public_key = certify.discover_public_key(args.kitten_bin, kitty_target)
        jterm_public_key = certify.discover_public_key(args.jterm_bin, jterm_target)

        unique_fixtures: dict[str, dict[str, Any]] = {}
        for fixture in command_to_fixture.values():
            fid = str(fixture.get("id", Path(str(fixture.get("_path", "unknown"))).stem))
            unique_fixtures[fid] = fixture

        print(f"\n==> Representative Fixture Replay ({len(unique_fixtures)} fixtures for {len(expected_commands)} commands)")
        for fid in sorted(unique_fixtures):
            fixture = unique_fixtures[fid]
            result = run_fixture(
                fixture=fixture,
                kitten_bin=args.kitten_bin,
                kitty_target=kitty_target,
                jterm_bin=args.jterm_bin,
                jterm_target=jterm_target,
                kitty_public_key=kitty_public_key,
                jterm_public_key=jterm_public_key,
            )
            fixture_outcomes[fid] = result
            if result.passed:
                print(f"PASS {fid}")
            else:
                print(f"FAIL {fid}")
                for err in result.errors:
                    print(f"  - {err}")

    finally:
        try:
            default_password_file.unlink(missing_ok=True)
        except Exception:
            pass

        for target in (kitty_target, jterm_target):
            if target.startswith("unix:"):
                try:
                    Path(target[len("unix:") :]).unlink(missing_ok=True)
                except Exception:
                    pass

        for proc in reversed(procs):
            try:
                proc.terminate()
            except Exception:
                pass
        for proc in reversed(procs):
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass

    report = build_report(
        spec_path=spec_path,
        command_to_fixture=command_to_fixture,
        fixture_outcomes=fixture_outcomes,
        gate_result=gate_result,
        aux_steps=aux_steps,
    )

    if missing_fixture_commands:
        for cmd in missing_fixture_commands:
            report["commands"].append(
                {
                    "command": cmd,
                    "status": "missing_fixture",
                    "fixture_id": None,
                    "fixture_path": None,
                    "errors": ["no representative fixture found"],
                }
            )
        report["summary"]["commands_failed"] = int(report["summary"]["commands_failed"]) + len(missing_fixture_commands)
        report["summary"]["commands_passed"] = int(report["summary"]["commands_passed"]) - len(missing_fixture_commands)
        report["summary"]["all_commands_passed"] = False

    report_path = Path(args.report_json)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"\nReport written: {report_path}")
    print_command_summary(report)

    rc = 0
    if gate_result is not None and gate_result.rc != 0:
        rc = 1
    if any(step.rc != 0 for step in aux_steps):
        rc = 1
    if not report.get("summary", {}).get("all_commands_passed", False):
        rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
