#!/usr/bin/env python3
"""Validate remote parity crypto vector files for schema and hex encoding."""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

REQUIRED = {
    "id",
    "algorithm",
    "key_hex",
    "nonce_hex",
    "aad_hex",
    "plaintext_hex",
    "ciphertext_hex",
    "tag_hex",
}


def is_hex(value: str) -> bool:
    if len(value) % 2 != 0:
        return False
    try:
        bytes.fromhex(value)
    except ValueError:
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", default="test/remote/parity/crypto_vectors")
    args = parser.parse_args()

    failures = 0
    files = sorted(glob.glob(os.path.join(args.dir, "*.json")))
    if not files:
        print("No vector files found", file=sys.stderr)
        return 2

    for path in files:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        missing = REQUIRED.difference(data.keys())
        if missing:
            failures += 1
            print(f"FAIL {path}: missing keys {sorted(missing)}")
            continue

        for field in (
            "key_hex",
            "nonce_hex",
            "aad_hex",
            "plaintext_hex",
            "ciphertext_hex",
            "tag_hex",
        ):
            value = str(data.get(field, ""))
            if value and not is_hex(value):
                failures += 1
                print(f"FAIL {path}: field {field} is not valid hex")

        print(f"PASS {path}")

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
