#!/usr/bin/env python3
"""Normalize remote-control outputs for kitty/jterm parity comparisons."""

from __future__ import annotations

import argparse
import json
from typing import Any, Iterable

DEFAULT_DYNAMIC_KEYS = {
    "id",
    "pid",
    "window_id",
    "tab_id",
    "os_window_id",
    "kitty_window_id",
    "timestamp",
    "created_at",
    "updated_at",
    "recent",
    "last_focus",
    "kitty_public_key",
}


def _normalize(value: Any, ignore_keys: set[str]) -> Any:
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key in sorted(value.keys()):
            if key in ignore_keys:
                continue
            out[key] = _normalize(value[key], ignore_keys)
        return out
    if isinstance(value, list):
        return [_normalize(v, ignore_keys) for v in value]
    return value


def _extract_ls_os_windows(value: Any) -> Any | None:
    data = value
    if isinstance(value, dict) and value.get("ok") is True and isinstance(value.get("data"), dict):
        data = value["data"]

    if isinstance(data, dict):
        os_windows = data.get("os_windows")
        if isinstance(os_windows, list):
            return os_windows
        return None

    if isinstance(data, list):
        return data

    return None


def _canonicalize_ls(value: Any) -> Any | None:
    os_windows = _extract_ls_os_windows(value)
    if os_windows is None:
        return None

    total_tabs = 0
    total_windows = 0
    for os_window in os_windows:
        if not isinstance(os_window, dict):
            continue
        tabs = os_window.get("tabs")
        if not isinstance(tabs, list):
            tabs = []
        total_tabs += len(tabs)
        for tab in tabs:
            if not isinstance(tab, dict):
                continue
            windows = tab.get("windows")
            if not isinstance(windows, list):
                windows = []
            total_windows += len(windows)

    return {
        "ls": {
            "has_os_windows": len(os_windows) > 0,
            "has_tabs": total_tabs > 0,
            "has_windows": total_windows > 0,
        }
    }


def normalize_json_value(value: Any, ignore_keys: Iterable[str] | None = None) -> Any:
    keys = set(DEFAULT_DYNAMIC_KEYS)
    if ignore_keys:
        keys.update(ignore_keys)
    canonicalized = _canonicalize_ls(value)
    if canonicalized is not None:
        value = canonicalized
    return _normalize(value, keys)


def normalize_json_text(raw: str, ignore_keys: Iterable[str] | None = None) -> str:
    value = json.loads(raw)
    normalized = normalize_json_value(value, ignore_keys=ignore_keys)
    return json.dumps(normalized, sort_keys=True, separators=(",", ":"))


def _main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", help="JSON input string. If omitted, reads stdin.")
    parser.add_argument(
        "--ignore-key",
        action="append",
        default=[],
        help="Additional key to strip while normalizing (repeatable).",
    )
    args = parser.parse_args()

    raw = args.input
    if raw is None:
        import sys

        raw = sys.stdin.read()

    out = normalize_json_text(raw, ignore_keys=args.ignore_key)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
