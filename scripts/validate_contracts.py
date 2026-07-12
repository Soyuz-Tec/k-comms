#!/usr/bin/env python3
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
for p in (root/'contracts/json-schema').glob('*.json'):
    json.loads(p.read_text())
for p in [root/'contracts/openapi/openapi.yaml', root/'contracts/asyncapi/asyncapi.yaml']:
    text=p.read_text()
    if not text.strip() or '	' in text: raise SystemExit(f'invalid contract: {p}')
print('Contract validation passed')
