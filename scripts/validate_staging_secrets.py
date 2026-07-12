#!/usr/bin/env python3
"""Reject empty or example placeholder values in staging env files."""

from __future__ import annotations

import re
import sys
from pathlib import Path


KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()

    if not path.is_file():
        return [f"{path}: file does not exist"]

    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            errors.append(f"{path}:{number}: expected KEY=VALUE")
            continue

        key, value = line.split("=", 1)
        if not KEY.fullmatch(key):
            errors.append(f"{path}:{number}: invalid key {key!r}")
        if key in seen:
            errors.append(f"{path}:{number}: duplicate key {key}")
        seen.add(key)

        if not value.strip():
            errors.append(f"{path}:{number}: {key} is empty")
        elif "CHANGE_ME" in value:
            errors.append(f"{path}:{number}: {key} still contains CHANGE_ME")

    if not seen:
        errors.append(f"{path}: no secret values found")
    return errors


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: validate_staging_secrets.py ENV_FILE [ENV_FILE ...]")

    errors = [error for argument in sys.argv[1:] for error in validate(Path(argument))]
    if errors:
        raise SystemExit("Staging secret validation failed:\n" + "\n".join(errors))

    print(f"Staging secret validation passed: {len(sys.argv) - 1} file(s)")


if __name__ == "__main__":
    main()
