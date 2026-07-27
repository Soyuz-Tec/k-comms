#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
acquire_deploy_lock

was_active=false
if unit_active k-comms-app.service; then
  was_active=true
  systemctl stop k-comms-app.service
fi

restart_app() {
  if [[ "$was_active" == true ]] && ! unit_active k-comms-app.service; then
    systemctl start k-comms-app.service || true
  fi
}
trap restart_app EXIT

backup_path="$("${SCRIPT_DIR}/backup.sh")"

if [[ "$was_active" == true ]]; then
  systemctl start k-comms-app.service
  "${SCRIPT_DIR}/verify.sh" --environment-file "$K_COMMS_ENVIRONMENT_FILE"
fi

trap - EXIT
log "completed application-consistent backup: ${backup_path}"
