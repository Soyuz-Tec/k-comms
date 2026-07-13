#!/usr/bin/env bash
set -euo pipefail
mix format --check-formatted
mix compile --warnings-as-errors
mix test
python3 scripts/validate_contracts.py
python3 scripts/validate_docs.py
python3 scripts/test_validate_architecture.py
python3 scripts/validate_architecture.py
