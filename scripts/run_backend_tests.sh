#!/usr/bin/env bash
set -euo pipefail

lane="${1:-full}"

case "$lane" in
  full)
    exec mix test --warnings-as-errors
    ;;
  unit)
    exec mix test --only unit --warnings-as-errors
    ;;
  integration)
    exec mix test --only integration --warnings-as-errors
    ;;
  concurrency)
    exec mix test --only concurrency --warnings-as-errors --trace
    ;;
  coverage)
    cleanup_coverage_exports() {
      find apps -type f -path '*/cover/*.coverdata' -delete
      find apps -type d -name cover -empty -delete
      find cover -maxdepth 1 -type f -name '*.coverdata' -delete 2>/dev/null || true
    }

    # Aggregate only exports from this run and leave the worktree clean.
    cleanup_coverage_exports
    trap cleanup_coverage_exports EXIT
    mix test --cover --export-coverage k-comms-baseline --warnings-as-errors
    mix test.coverage
    ;;
  *)
    printf 'unknown backend test lane: %s\n' "$lane" >&2
    printf 'expected one of: full, unit, integration, concurrency, coverage\n' >&2
    exit 2
    ;;
esac
