#!/usr/bin/env python3
"""Wire protocol parity checks (DCS framing, encrypted envelope, server compatibility)."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

DCS_PREFIX = b"\x1bP@kitty-cmd"
DCS_SUFFIX = b"\x1b\\"


def default_jterm_bin() -> str:
    return "zig-out/bin/jterm"


def wait_for_socket(path: str, timeout: float = 15.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.05)
    return False


def capture_client_frame(
    client_cmd: list[str],
    response: bytes,
    timeout: float = 8.0,
    env: dict[str, str] | None = None,
) -> tuple[bytes, int, str, str]:
    path = f"/tmp/rc-capture-{os.getpid()}-{threading.get_ident()}.sock"
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)
    captured: dict[str, Any] = {"data": b""}

    def server() -> None:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        data = b""
        conn.settimeout(1.0)
        try:
            while True:
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    break
                if not chunk:
                    break
                data += chunk
                if len(data) > 2 * 1024 * 1024:
                    break
                if data.endswith(DCS_SUFFIX) or b"\n" in data:
                    break
        finally:
            captured["data"] = data
            try:
                conn.sendall(response)
            except Exception:
                pass
            conn.close()

    thread = threading.Thread(target=server, daemon=True)
    thread.start()

    cmd = list(client_cmd)
    cmd = [arg.replace("__SOCKET__", f"unix:{path}") for arg in cmd]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)

    thread.join(timeout=2.0)
    srv.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    return captured["data"], proc.returncode, proc.stdout, proc.stderr


def parse_dcs_payload(frame: bytes) -> dict[str, Any] | None:
    if not (frame.startswith(DCS_PREFIX) and frame.endswith(DCS_SUFFIX)):
        return None
    payload = frame[len(DCS_PREFIX) : -len(DCS_SUFFIX)]
    try:
        return json.loads(payload)
    except Exception:
        return None


def discover_kitty_public_key(kitty_bin: str, kitten_bin: str) -> str | None:
    socket_path = f"/tmp/kitty-protocol-capture-{os.getpid()}.sock"
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    proc = subprocess.Popen(
        [
            kitty_bin,
            "-o",
            "single_instance=no",
            "-o",
            "allow_remote_control=yes",
            "--listen-on",
            f"unix:{socket_path}",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    try:
        if not wait_for_socket(socket_path):
            return None

        probe = subprocess.run(
            [kitten_bin, "@", f"--to=unix:{socket_path}", "ls", "--all-env-vars"],
            capture_output=True,
            text=True,
            timeout=8.0,
        )
        if probe.returncode != 0:
            return None
        try:
            parsed = json.loads(probe.stdout)
        except Exception:
            return None
        # kitty ls output is a list of os windows; scan nested env maps.
        if isinstance(parsed, dict):
            value = parsed.get("kitty_public_key")
            if isinstance(value, str) and value:
                return value
        if isinstance(parsed, list):
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
                        env_map = window.get("env")
                        if isinstance(env_map, dict):
                            value = env_map.get("KITTY_PUBLIC_KEY")
                            if isinstance(value, str) and value:
                                return value
        return None
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass


def send_raw(socket_path: str, payload: bytes, timeout: float = 3.0) -> bytes:
    cli = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    cli.connect(socket_path)
    cli.sendall(payload)
    cli.settimeout(timeout)
    out = b""
    try:
        while True:
            chunk = cli.recv(4096)
            if not chunk:
                break
            out += chunk
            if out.endswith(DCS_SUFFIX) or b"\n" in out:
                break
    except socket.timeout:
        pass
    finally:
        cli.close()
    return out


def check_capture_frames(kitty_bin: str, kitten_bin: str, jterm_bin: str) -> list[str]:
    errors: list[str] = []
    # Response includes both DCS and newline JSON for maximal client compatibility during capture.
    mixed_response = DCS_PREFIX + b'{"ok":true}' + DCS_SUFFIX + b'\n{"ok":true}\n'

    k_frame, _, _, _ = capture_client_frame(
        [kitten_bin, "@", "--to=__SOCKET__", "ls"],
        mixed_response,
    )
    if not (k_frame.startswith(DCS_PREFIX) and k_frame.endswith(DCS_SUFFIX)):
        errors.append("kitten client request is not DCS framed")

    j_frame, _, _, _ = capture_client_frame(
        [
            jterm_bin,
            "--remote-control-default-no-response=false",
            "@",
            "--to=__SOCKET__",
            "ls",
            "--response",
        ],
        mixed_response,
    )
    if not (j_frame.startswith(DCS_PREFIX) and j_frame.endswith(DCS_SUFFIX)):
        errors.append("jterm client request is not DCS framed")

    kitty_public_key = os.environ.get("KITTY_PUBLIC_KEY") or discover_kitty_public_key(kitty_bin, kitten_bin)
    if not kitty_public_key:
        errors.append("unable to discover KITTY_PUBLIC_KEY for encrypted capture")
        return errors

    enc_env = os.environ.copy()
    enc_env["KITTY_PUBLIC_KEY"] = kitty_public_key
    enc_frame, _, _, _ = capture_client_frame(
        [kitten_bin, "@", "--to=__SOCKET__", "--password", "demo", "ls"],
        mixed_response,
        env=enc_env,
    )
    enc = parse_dcs_payload(enc_frame)
    if not isinstance(enc, dict):
        errors.append("kitten encrypted request is not valid DCS JSON")
    else:
        for key in ("version", "iv", "tag", "pubkey", "encrypted"):
            if key not in enc:
                errors.append(f"kitten encrypted request missing key: {key}")

    return errors


def check_server_accepts_dcs(kitty_bin: str, jterm_bin: str) -> list[str]:
    errors: list[str] = []

    # Kitty baseline server behavior.
    kitty_sock = f"/tmp/kitty-protocol-{os.getpid()}.sock"
    try:
        os.unlink(kitty_sock)
    except FileNotFoundError:
        pass
    k_proc = subprocess.Popen(
        [kitty_bin, "-o", "single_instance=no", "-o", "allow_remote_control=yes", "--listen-on", f"unix:{kitty_sock}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    try:
        if not wait_for_socket(kitty_sock):
            errors.append("kitty server socket did not become ready")
        else:
            req = DCS_PREFIX + b'{"cmd":"ls","version":[0,26,0],"payload":{"output_format":"json"}}' + DCS_SUFFIX
            resp = send_raw(kitty_sock, req)
            if not (resp.startswith(DCS_PREFIX) and resp.endswith(DCS_SUFFIX)):
                errors.append("kitty server did not return DCS framed response")
    finally:
        k_proc.terminate()
        try:
            k_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            k_proc.kill()
            k_proc.wait(timeout=5)
        try:
            os.unlink(kitty_sock)
        except FileNotFoundError:
            pass

    # jterm server parity expectation.
    jterm_sock = f"/tmp/jterm-protocol-{os.getpid()}.sock"
    try:
        os.unlink(jterm_sock)
    except FileNotFoundError:
        pass

    env = os.environ.copy()
    env["JTERM_LISTEN_ON"] = f"unix:{jterm_sock}"
    j_proc = subprocess.Popen(
        [jterm_bin, "--allow-remote-control=true"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    try:
        if not wait_for_socket(jterm_sock):
            errors.append("jterm server socket did not become ready")
        else:
            req = DCS_PREFIX + b'{"cmd":"ls","version":[0,26,0],"payload":{"output_format":"json"}}' + DCS_SUFFIX
            resp = send_raw(jterm_sock, req)
            if not (resp.startswith(DCS_PREFIX) and resp.endswith(DCS_SUFFIX)):
                errors.append("jterm server does not accept/return DCS framed protocol")
    finally:
        j_proc.terminate()
        try:
            j_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            j_proc.kill()
            j_proc.wait(timeout=5)
        try:
            os.unlink(jterm_sock)
        except FileNotFoundError:
            pass

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kitty-bin", default="/Applications/kitty.app/Contents/MacOS/kitty")
    parser.add_argument("--kitten-bin", default="/Applications/kitty.app/Contents/MacOS/kitten")
    parser.add_argument("--jterm-bin", default=default_jterm_bin())
    parser.add_argument("--max-errors", type=int, default=100)
    args = parser.parse_args()

    errors: list[str] = []
    errors.extend(check_capture_frames(args.kitty_bin, args.kitten_bin, args.jterm_bin))
    errors.extend(check_server_accepts_dcs(args.kitty_bin, args.jterm_bin))

    if errors:
        print(f"Protocol parity check failed: {len(errors)} issue(s)")
        for err in errors[: args.max_errors]:
            print(f"  - {err}")
        if len(errors) > args.max_errors:
            print(f"  ... {len(errors) - args.max_errors} more")
        return 1

    print("Protocol parity check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
