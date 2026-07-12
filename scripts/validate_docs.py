#!/usr/bin/env python3
"""Validate repository-owned Markdown links using UTF-8 consistently."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
IGNORED_PARTS = {".git", "_build", "deps", "node_modules", ".venv", "cover", "doc"}
errors: list[str] = []
files = [
    path
    for path in ROOT.rglob("*.md")
    if not any(part in IGNORED_PARTS for part in path.relative_to(ROOT).parts)
]

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
