#!/usr/bin/env bash
set -Eeuo pipefail
# Sourced after common.sh by maintenance commands. Never source runtime.env.

operation_clock() {
  python3 "${SCRIPT_DIR}/operations.py" monotonic
}

operation_begin() {
  require_command python3
  operation_kind=$1
  operation_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  operation_started_ns="$(operation_clock)"
  operation_phase=
  operation_phase_started_ns=$operation_started_ns
  operation_durations=()
}

operation_phase_end() {
  if [[ -n "$operation_phase" ]]; then
    local now_ns
    now_ns="$(operation_clock)" || return 1
    operation_durations+=(--duration "${operation_phase}=$((now_ns - operation_phase_started_ns))")
    operation_phase=
  fi
}

operation_phase_begin() {
  operation_phase_end
  operation_phase=$1
  operation_phase_started_ns="$(operation_clock)"
}

operation_record() {
  local status=$1
  local failed_phase=${operation_phase:-finalization}
  shift
  operation_phase_end || return 1
  local arguments=(
    record --kind "$operation_kind" --status "$status"
    --started-at "$operation_started_at" --started-ns "$operation_started_ns"
    --receipts "$K_COMMS_RECEIPT_DIR"
  )
  if [[ "$status" != success ]]; then
    arguments+=(--failed-phase "$failed_phase")
  fi
  python3 "${SCRIPT_DIR}/operations.py" "${arguments[@]}" "${operation_durations[@]}" "$@"
}
