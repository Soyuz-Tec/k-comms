#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/operations-common.sh"

require_root
acquire_deploy_lock

was_active=false
writers_stopped=false
health_restored=false
outage_end_ns=
backup_path=
maintenance_complete=false
unit_active k-comms-app.service && was_active=true
operation_begin maintenance

finish_maintenance() {
  local exit_status=$?
  local failed_phase=${operation_phase:-finalization}
  trap - EXIT
  set +e
  if [[ "$was_active" == true && "$health_restored" == false ]]; then
    operation_phase_begin recovery
    if systemctl start k-comms-app.service &&
      "${SCRIPT_DIR}/verify.sh" --environment-file "$K_COMMS_ENVIRONMENT_FILE"; then
      health_restored=true
      outage_end_ns="$(operation_clock)"
    else
      exit_status=1
      log "backup maintenance recovery has not restored application health"
    fi
  fi
  local status=failed
  if [[ "$maintenance_complete" == true && "$exit_status" -eq 0 ]]; then
    status=success
  fi
  local arguments=(--backup-path "$backup_path")
  [[ "$was_active" == true ]] && arguments+=(--was-active)
  [[ "$writers_stopped" == true ]] && arguments+=(--writers-stopped)
  [[ "$health_restored" == true ]] && arguments+=(--health-restored)
  [[ -n "$outage_end_ns" ]] && arguments+=(--outage-end-ns "$outage_end_ns")
  [[ "$status" == failed ]] && arguments+=(--failed-phase "$failed_phase")
  operation_record "$status" "${arguments[@]}" || exit_status=1
  exit "$exit_status"
}
trap finish_maintenance EXIT

if [[ "$was_active" == true ]]; then
  operation_phase_begin stop
  systemctl stop k-comms-app.service
  writers_stopped=true
fi
operation_phase_begin backup
backup_path="$("${SCRIPT_DIR}/backup.sh")"

if [[ "$was_active" == true ]]; then
  operation_phase_begin recovery
  systemctl start k-comms-app.service
  "${SCRIPT_DIR}/verify.sh" --environment-file "$K_COMMS_ENVIRONMENT_FILE"
  health_restored=true
  outage_end_ns="$(operation_clock)"
fi

maintenance_complete=true
log "completed application-consistent backup: ${backup_path}"
