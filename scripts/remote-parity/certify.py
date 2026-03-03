#!/usr/bin/env python3
"""Run parity fixtures against kitty and jterm remote-control endpoints."""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from normalize import normalize_json_value


@dataclass
class CommandResult:
    rc: int
    stdout: str
    stderr: str
    parsed: Any | None


def default_jterm_bin() -> str:
    return "zig-out/bin/jterm"


def run_remote(binary: str, target: str, op: dict[str, Any]) -> CommandResult:
    binary_name = Path(binary).name.lower()
    args = [binary]
    if "jterm" in binary_name:
        # Keep command output deterministic for parity runs regardless of local user config.
        args.append("--remote-control-default-no-response=false")

    args.extend(["@", f"--to={target}"])
    args.extend(op.get("global_options", []))
    args.extend(op.get("args", []))

    env = os.environ.copy()
    for key, value in op.get("env", {}).items():
        env[str(key)] = str(value)

    timeout = float(op.get("timeout_seconds", 10))
    try:
        proc = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        return CommandResult(
            rc=124,
            stdout=(exc.stdout or "").strip() if isinstance(exc.stdout, str) else "",
            stderr="remote command timed out",
            parsed=None,
        )
    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()
    parsed = None
    if stdout:
        try:
            parsed = json.loads(stdout)
        except json.JSONDecodeError:
            parsed = None
    return CommandResult(rc=proc.returncode, stdout=stdout, stderr=stderr, parsed=parsed)


def has_ls_hierarchy(binary: str, parsed: Any | None) -> bool:
    binary_name = Path(binary).name.lower()
    if "jterm" in binary_name:
        windows = extract_jterm_windows(parsed)
    else:
        windows = extract_kitty_windows(parsed)
    return windows is not None


def assert_operation(name: str, result: CommandResult, op: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    if "known_result_codes" in op:
        known_codes = {int(v) for v in op["known_result_codes"]}
        if result.rc not in known_codes:
            errors.append(f"{name}: expected rc in {sorted(known_codes)} got rc={result.rc}")
        return errors

    if "expect_rc" in op and result.rc != op["expect_rc"]:
        errors.append(f"{name}: expected rc={op['expect_rc']} got rc={result.rc}")

    if op.get("expect_ok", False):
        if not isinstance(result.parsed, dict):
            errors.append(f"{name}: expected JSON response with ok=true")
        elif result.parsed.get("ok") is not True:
            errors.append(f"{name}: expected ok=true got {result.parsed.get('ok')!r}")

    if "expect_error_contains" in op:
        needle = str(op["expect_error_contains"])
        haystack = result.stderr or result.stdout
        if needle not in haystack:
            errors.append(f"{name}: expected error text containing {needle!r}")

    if op.get("expect_stdout_empty", False) and result.stdout:
        errors.append(f"{name}: expected empty stdout")

    return errors


def compare_operation(
    name: str,
    kitty: CommandResult,
    jterm: CommandResult,
    op: dict[str, Any],
    fixture: dict[str, Any],
) -> list[str]:
    if not op.get("compare", True):
        return []

    errors: list[str] = []
    if kitty.rc != jterm.rc and op.get("compare_rc", True):
        errors.append(f"{name}: rc mismatch kitty={kitty.rc} jterm={jterm.rc}")

    ignore_keys = list(fixture.get("ignore_keys", [])) + list(op.get("ignore_keys", []))

    if kitty.parsed is not None and jterm.parsed is not None:
        command = ""
        args = op.get("args", [])
        if isinstance(args, list) and args:
            command = str(args[0])

        if command in {"new-window", "new-tab", "launch"}:
            if (
                isinstance(kitty.parsed, int)
                and isinstance(jterm.parsed, int)
                and kitty.parsed > 0
                and jterm.parsed > 0
            ):
                return errors

        kn = normalize_json_value(kitty.parsed, ignore_keys=ignore_keys)
        jn = normalize_json_value(jterm.parsed, ignore_keys=ignore_keys)
        if kn != jn:
            kitty_summary = _truncate(json.dumps(kn, sort_keys=True), 600)
            jterm_summary = _truncate(json.dumps(jn, sort_keys=True), 600)
            errors.append(
                f"{name}: normalized JSON mismatch\n"
                f"  kitty={kitty_summary}\n"
                f"  jterm={jterm_summary}"
            )
        return errors

    kitty_stdout = normalize_stdout_for_compare(kitty.stdout, op)
    jterm_stdout = normalize_stdout_for_compare(jterm.stdout, op)
    if kitty_stdout != jterm_stdout:
        errors.append(
            f"{name}: stdout mismatch "
            f"kitty={_truncate(kitty_stdout, 600)!r} "
            f"jterm={_truncate(jterm_stdout, 600)!r}"
        )

    return errors


def _truncate(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[:limit] + "...<truncated>"


def normalize_stdout_for_compare(stdout: str, op: dict[str, Any]) -> str:
    command = ""
    args = op.get("args", [])
    if isinstance(args, list) and args:
        command = str(args[0])

    raw = stdout.strip()
    if command in {"new-window", "new-tab", "launch"}:
        try:
            value = int(raw)
            if value > 0:
                return "<created-id>"
        except Exception:
            pass
    if command in {"get-colors", "get-text"}:
        return "<non-empty>" if raw else "<empty>"
    return raw


def extract_kitty_windows(parsed: Any | None) -> list[dict[str, Any]] | None:
    if not isinstance(parsed, list):
        return None
    windows: list[dict[str, Any]] = []
    for os_window in parsed:
        if not isinstance(os_window, dict):
            continue
        tabs = os_window.get("tabs")
        if not isinstance(tabs, list):
            continue
        for tab in tabs:
            if not isinstance(tab, dict):
                continue
            tab_windows = tab.get("windows")
            if not isinstance(tab_windows, list):
                continue
            for window in tab_windows:
                if isinstance(window, dict):
                    windows.append(window)
    return windows


def extract_jterm_windows(parsed: Any | None) -> list[dict[str, Any]] | None:
    if not isinstance(parsed, dict):
        return None

    data: dict[str, Any] | None = None
    if parsed.get("ok") is True:
        maybe_data = parsed.get("data")
        if isinstance(maybe_data, dict):
            data = maybe_data
    else:
        data = parsed

    if data is None:
        return None

    os_windows = data.get("os_windows")
    if not isinstance(os_windows, list):
        return None

    windows: list[dict[str, Any]] = []
    for os_window in os_windows:
        if not isinstance(os_window, dict):
            continue
        tabs = os_window.get("tabs")
        if not isinstance(tabs, list):
            continue
        for tab in tabs:
            if not isinstance(tab, dict):
                continue
            tab_windows = tab.get("windows")
            if not isinstance(tab_windows, list):
                continue
            for window in tab_windows:
                if isinstance(window, dict):
                    windows.append(window)
    return windows


def _extract_kitty_public_key_from_parsed(parsed: Any | None) -> str | None:
    if not isinstance(parsed, list):
        return None
    for os_window in parsed:
        if not isinstance(os_window, dict):
            continue
        tabs = os_window.get("tabs")
        if not isinstance(tabs, list):
            continue
        for tab in tabs:
            if not isinstance(tab, dict):
                continue
            windows = tab.get("windows")
            if not isinstance(windows, list):
                continue
            for window in windows:
                if not isinstance(window, dict):
                    continue
                env = window.get("env")
                if isinstance(env, dict):
                    value = env.get("KITTY_PUBLIC_KEY")
                    if isinstance(value, str) and value:
                        return value
    return None


def _extract_jterm_public_key_from_parsed(parsed: Any | None) -> str | None:
    if not isinstance(parsed, dict):
        return None

    data: Any = parsed
    if parsed.get("ok") is True and isinstance(parsed.get("data"), dict):
        data = parsed["data"]
    if not isinstance(data, dict):
        return None

    direct = data.get("kitty_public_key")
    if isinstance(direct, str) and direct:
        return direct

    os_windows = data.get("os_windows")
    if not isinstance(os_windows, list):
        return None
    for os_window in os_windows:
        if not isinstance(os_window, dict):
            continue
        tabs = os_window.get("tabs")
        if not isinstance(tabs, list):
            continue
        for tab in tabs:
            if not isinstance(tab, dict):
                continue
            windows = tab.get("windows")
            if not isinstance(windows, list):
                continue
            for window in windows:
                if not isinstance(window, dict):
                    continue
                env = window.get("env")
                if isinstance(env, dict):
                    value = env.get("KITTY_PUBLIC_KEY")
                    if isinstance(value, str) and value:
                        return value
                if isinstance(env, list):
                    for pair in env:
                        if not isinstance(pair, dict):
                            continue
                        key = pair.get("key")
                        value = pair.get("value")
                        if key == "KITTY_PUBLIC_KEY" and isinstance(value, str) and value:
                            return value
    return None


def discover_public_key(binary: str, target: str) -> str | None:
    probe = run_remote(binary, target, {"args": ["ls", "--all-env-vars"], "timeout_seconds": 5})
    if probe.rc != 0:
        return None
    binary_name = Path(binary).name.lower()
    if "jterm" in binary_name:
        return _extract_jterm_public_key_from_parsed(probe.parsed)
    return _extract_kitty_public_key_from_parsed(probe.parsed)


def op_uses_password_transport(op: dict[str, Any]) -> bool:
    options = [str(v) for v in op.get("global_options", [])]
    if any(v.startswith("--use-password=never") or v == "--use-password=never" for v in options):
        return False
    return any(
        v.startswith("--password=")
        or v == "--password"
        or v.startswith("--password-file")
        or v.startswith("--password-env")
        or v.startswith("--use-password=always")
        for v in options
    )


def load_fixtures(directory: str, only: str | None) -> list[dict[str, Any]]:
    fixtures: list[dict[str, Any]] = []
    pattern = os.path.join(directory, "**", "*.json")
    for path in sorted(glob.glob(pattern, recursive=True)):
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        data.setdefault("_path", path)
        fixture_id = str(data.get("id", Path(path).stem))
        if only and only not in fixture_id:
            continue
        fixtures.append(data)
    return fixtures


def ensure_ready(binary: str, target: str, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    op: dict[str, Any] = {"args": ["ls"], "timeout_seconds": 3}
    while time.time() < deadline:
        result = run_remote(binary, target, op)
        if result.rc != 0:
            time.sleep(0.25)
            continue
        if has_ls_hierarchy(binary, result.parsed):
            return True
        time.sleep(0.25)
    return False


def spawn_apps(args: argparse.Namespace) -> list[subprocess.Popen[str]]:
    processes: list[subprocess.Popen[str]] = []

    kitty_bin = args.kitty_bin
    kitten_bin = args.kitten_bin
    kitty_target = args.kitty_target

    if Path(kitten_bin).name == "kitten":
        candidate = str(Path(kitten_bin).with_name("kitty"))
        if Path(candidate).exists():
            kitty_bin = candidate

    kitty_cmd = [
        kitty_bin,
        "-o",
        "single_instance=no",
        "-o",
        "allow_remote_control=yes",
        "--listen-on",
        kitty_target,
    ]
    kitty_proc = subprocess.Popen(kitty_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    processes.append(kitty_proc)

    jterm_env = os.environ.copy()
    jterm_env["JTERM_LISTEN_ON"] = args.jterm_target
    jterm_cmd = [args.jterm_bin, "--allow-remote-control=true"]
    jterm_proc = subprocess.Popen(jterm_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, env=jterm_env)
    processes.append(jterm_proc)

    if not ensure_ready(args.kitten_bin, args.kitty_target):
        raise RuntimeError("kitty remote endpoint did not become ready")
    if not ensure_ready(args.jterm_bin, args.jterm_target):
        raise RuntimeError("jterm remote endpoint did not become ready")

    return processes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["fixtures", "corpus", "phases", "all"], default="all")
    parser.add_argument("--fixtures-dir", default="test/remote/parity/fixtures")
    parser.add_argument("--corpus-dir", default="test/remote/parity/corpus")
    parser.add_argument("--phases-dir", default="test/remote/parity/phases")
    parser.add_argument("--only", help="Only run fixture IDs containing this substring.")
    parser.add_argument("--kitten-bin", default=os.environ.get("KITTEN_BIN", "/Applications/kitty.app/Contents/MacOS/kitten"))
    parser.add_argument("--kitty-bin", default=os.environ.get("KITTY_BIN", "/Applications/kitty.app/Contents/MacOS/kitty"))
    parser.add_argument("--jterm-bin", default=os.environ.get("JTERM_BIN", default_jterm_bin()))
    # Keep parity runs isolated from ambient shell listener variables.
    parser.add_argument("--kitty-target", default="unix:/tmp/kitty-parity.sock")
    parser.add_argument("--jterm-target", default="unix:/tmp/jterm-parity.sock")
    parser.add_argument("--spawn-apps", action="store_true", help="Spawn kitty and jterm for this run.")
    parser.add_argument("--strict-known-gaps", action="store_true", help="Fail when a known gap is encountered.")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.spawn_apps:
        pid = os.getpid()
        if args.kitty_target == "unix:/tmp/kitty-parity.sock":
            args.kitty_target = f"unix:/tmp/kitty-parity-{pid}.sock"
        if args.jterm_target == "unix:/tmp/jterm-parity.sock":
            args.jterm_target = f"unix:/tmp/jterm-parity-{pid}.sock"

    fixtures: list[dict[str, Any]] = []
    if args.mode in {"fixtures", "all"}:
        fixtures.extend(load_fixtures(args.fixtures_dir, args.only))
    if args.mode in {"corpus", "all"}:
        fixtures.extend(load_fixtures(args.corpus_dir, args.only))
    if args.mode in {"phases", "all"}:
        fixtures.extend(load_fixtures(args.phases_dir, args.only))

    if not fixtures:
        print("No fixtures found.", file=sys.stderr)
        return 2

    procs: list[subprocess.Popen[str]] = []
    default_password_file = Path("/tmp/jterm-parity-password.txt")
    kitty_public_key: str | None = None
    jterm_public_key: str | None = None
    try:
        default_password_file.write_text("demo\n", encoding="utf-8")

        if args.spawn_apps:
            procs = spawn_apps(args)

        kitty_public_key = discover_public_key(args.kitten_bin, args.kitty_target)
        jterm_public_key = discover_public_key(args.jterm_bin, args.jterm_target)

        passed = 0
        failed = 0
        xfail = 0
        skipped = 0

        for fixture in fixtures:
            fid = str(fixture.get("id", "unknown"))
            desc = fixture.get("description", "")
            if fixture.get("skip", False):
                skipped += 1
                print(f"SKIP {fid}: {desc}")
                continue

            if args.verbose:
                print(f"RUN  {fid}: {desc}")

            ops = fixture.get("operations", [])
            fixture_errors: list[str] = []

            for idx, op in enumerate(ops):
                name = op.get("name", f"op-{idx + 1}")
                kitty_op = dict(op)
                jterm_op = dict(op)
                if op_uses_password_transport(op):
                    if kitty_public_key:
                        kitty_env = dict(kitty_op.get("env", {}))
                        kitty_env["KITTY_PUBLIC_KEY"] = kitty_public_key
                        kitty_op["env"] = kitty_env
                    if jterm_public_key:
                        jterm_env = dict(jterm_op.get("env", {}))
                        jterm_env["KITTY_PUBLIC_KEY"] = jterm_public_key
                        jterm_op["env"] = jterm_env

                kitty = run_remote(args.kitten_bin, args.kitty_target, kitty_op)
                jterm = run_remote(args.jterm_bin, args.jterm_target, jterm_op)

                op_errors = []
                op_errors.extend(assert_operation(f"{name}/kitty", kitty, op))
                op_errors.extend(assert_operation(f"{name}/jterm", jterm, op))
                op_errors.extend(compare_operation(name, kitty, jterm, op, fixture))

                if op_errors:
                    fixture_errors.extend(op_errors)
                    if args.verbose:
                        print(f"  {name}: kitty rc={kitty.rc} out={kitty.stdout!r} err={kitty.stderr!r}")
                        print(f"  {name}: jterm rc={jterm.rc} out={jterm.stdout!r} err={jterm.stderr!r}")

                if "delay_after_seconds" in op:
                    time.sleep(float(op["delay_after_seconds"]))

            known_gap = bool(fixture.get("known_gap", False))
            if fixture_errors:
                if known_gap and not args.strict_known_gaps:
                    xfail += 1
                    print(f"XFAIL {fid}: {desc}")
                    for err in fixture_errors:
                        print(f"  - {err}")
                else:
                    failed += 1
                    print(f"FAIL {fid}: {desc}")
                    for err in fixture_errors:
                        print(f"  - {err}")
            else:
                passed += 1
                print(f"PASS {fid}: {desc}")

        print(
            f"\nSummary: passed={passed} failed={failed} xfail={xfail} skipped={skipped} total={len(fixtures)}"
        )
        return 0 if failed == 0 and (xfail == 0 or not args.strict_known_gaps) else 1
    finally:
        for target in (args.kitty_target, args.jterm_target):
            if isinstance(target, str) and target.startswith("unix:"):
                path = target[len("unix:") :]
                try:
                    Path(path).unlink(missing_ok=True)
                except Exception:
                    pass

        try:
            default_password_file.unlink(missing_ok=True)
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


if __name__ == "__main__":
    raise SystemExit(main())
