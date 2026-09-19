#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_root
require_command python3

arguments=(
  monitor --config "${K_COMMS_CONFIG_DIR}/monitoring.json"
  --state-dir "${K_COMMS_RECEIPT_DIR}/monitoring"
  --receipts "$K_COMMS_RECEIPT_DIR" --backup-root "$K_COMMS_BACKUP_ROOT"
  --storage-path "$K_COMMS_BACKUP_ROOT"
  --storage-path "$(expected_postgres_volume_path)"
  --storage-path "$(expected_minio_volume_path)"
)
if "${SCRIPT_DIR}/verify.sh" --environment-file "$K_COMMS_ENVIRONMENT_FILE"; then
  arguments+=(--healthy)
fi
python3 "${SCRIPT_DIR}/operations.py" "${arguments[@]}"
