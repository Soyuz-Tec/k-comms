#!/usr/bin/env python3
"""Validate repository-owned Markdown links using UTF-8 consistently."""

import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IGNORED_PARTS = {".git", "_build", "deps", "node_modules", ".venv", "cover", "doc"}
errors: list[str] = []


def markdown_files() -> list[Path]:
    files: list[Path] = []
    for directory, child_directories, filenames in os.walk(ROOT, topdown=True):
        child_directories[:] = [
            name for name in child_directories if name not in IGNORED_PARTS
        ]
        root = Path(directory)
        files.extend(root / name for name in filenames if name.endswith(".md"))
    return sorted(files)


files = markdown_files()

for path in files:
    text = path.read_text(encoding="utf-8")
    for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
        target = target.split("#", 1)[0]
        if not target or "://" in target or target.startswith("mailto:"):
            continue
        resolved = (path.parent / target).resolve()
        if not resolved.exists():
            errors.append(f"{path.relative_to(ROOT)} -> {target}")

if errors:
    raise SystemExit("Broken links:\n" + "\n".join(errors))

print(f"Documentation validation passed: {len(files)} Markdown files")
