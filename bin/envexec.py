#!/usr/bin/python3
"""Execute a command with variables from a literal KEY=value file."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


KEY_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def fail(message: str) -> "NoReturn":
    print(f"envexec: {message}", file=sys.stderr)
    raise SystemExit(2)


def main() -> None:
    if len(sys.argv) < 3:
        fail("usage: envexec.py ENV_FILE COMMAND [ARG ...]")

    path = Path(sys.argv[1])
    if not path.is_file():
        fail(f"environment file does not exist: {path}")

    environment = os.environ.copy()
    keys: set[str] = set()
    for number, original in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = original.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in original:
            fail(f"line {number}: expected KEY=value")
        key, value = original.split("=", 1)
        key = key.strip()
        if KEY_PATTERN.fullmatch(key) is None:
            fail(f"line {number}: invalid variable name")
        if key in keys:
            fail(f"line {number}: duplicate variable {key}")
        if "\x00" in value or "\r" in value or value != value.strip():
            fail(f"line {number}: invalid value for {key}")
        keys.add(key)
        environment[key] = value

    os.execvpe(sys.argv[2], sys.argv[2:], environment)


if __name__ == "__main__":
    main()
