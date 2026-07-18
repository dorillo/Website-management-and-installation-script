#!/usr/bin/env python3
"""Minimal editor for the application's deliberately simple KEY=value file."""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


KEY_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def parse(path: Path) -> list[tuple[str | None, str]]:
    entries: list[tuple[str | None, str]] = []
    keys: set[str] = set()

    for number, original in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = original.strip()
        if not stripped or stripped.startswith("#"):
            entries.append((None, original))
            continue
        if "=" not in original:
            raise ValueError(f"line {number}: expected KEY=value")
        key, value = original.split("=", 1)
        key = key.strip()
        if KEY_PATTERN.fullmatch(key) is None:
            raise ValueError(f"line {number}: invalid variable name")
        if key in keys:
            raise ValueError(f"line {number}: duplicate variable {key}")
        validate_value(value, key)
        keys.add(key)
        entries.append((key, value))

    return entries


def validate_value(value: str, key: str) -> None:
    if "\x00" in value or "\r" in value or "\n" in value:
        raise ValueError(f"{key}: control characters are forbidden")
    if value != value.strip():
        raise ValueError(f"{key}: leading or trailing spaces are forbidden")


def atomic_write(path: Path, content: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o640
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temporary, mode)
        if path.exists():
            os.chown(temporary, path.stat().st_uid, path.stat().st_gid)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def command_get(path: Path, key: str) -> int:
    for entry_key, value in parse(path):
        if entry_key == key:
            print(value)
            return 0
    return 1


def command_set(path: Path, key: str) -> int:
    if KEY_PATTERN.fullmatch(key) is None:
        raise ValueError("invalid variable name")
    value = sys.stdin.read()
    validate_value(value, key)
    entries = parse(path)
    replaced = False
    lines: list[str] = []

    for entry_key, entry_value in entries:
        if entry_key == key:
            lines.append(f"{key}={value}")
            replaced = True
        elif entry_key is None:
            lines.append(entry_value)
        else:
            lines.append(f"{entry_key}={entry_value}")

    if not replaced:
        if lines and lines[-1]:
            lines.append("")
        lines.append(f"{key}={value}")
    atomic_write(path, "\n".join(lines) + "\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("get", "set", "validate"))
    parser.add_argument("path", type=Path)
    parser.add_argument("key", nargs="?")
    arguments = parser.parse_args()

    if not arguments.path.is_file():
        raise ValueError(f"file does not exist: {arguments.path}")
    if arguments.command == "validate":
        parse(arguments.path)
        return 0
    if not arguments.key:
        parser.error("get and set require a key")
    if arguments.command == "get":
        return command_get(arguments.path, arguments.key)
    return command_set(arguments.path, arguments.key)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(f"envctl: {error}", file=sys.stderr)
        raise SystemExit(2) from None
