#!/usr/bin/env bash
set -euo pipefail
mix format --check-formatted
mix compile --warnings-as-errors
mix test
python3 scripts/validate_contracts.py
python3 scripts/validate_docs.py
