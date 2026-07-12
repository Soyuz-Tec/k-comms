#!/usr/bin/env python3
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
errors=[]
files=list(root.rglob('*.md'))
for p in files:
    text=p.read_text()
    for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', text):
        target=target.split('#',1)[0]
        if not target or '://' in target or target.startswith('mailto:'): continue
        resolved=(p.parent/target).resolve()
        if not resolved.exists(): errors.append(f'{p.relative_to(root)} -> {target}')
if errors:
    raise SystemExit("Broken links:\n" + "\n".join(errors))
print(f'Documentation validation passed: {len(files)} Markdown files')
