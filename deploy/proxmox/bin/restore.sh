#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

backup_dir=
confirmation=
restore_runtime=false

while (($#)); do
  case "$1" in
    --backup) backup_dir=${2:-}; shift 2 ;;
    --confirmation) confirmation=${2:-}; shift 2 ;;
    --restore-runtime-config) restore_runtime=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
for command in pg_restore podman sha256sum systemctl tar; do
  require_command "$command"
done
[[ "$confirmation" == restore-k-comms-backup-v1 ]] ||
  die "restore requires --confirmation restore-k-comms-backup-v1"
[[ -n "$backup_dir" ]] || die "--backup is required"
backup_dir="$(realpath -e "$backup_dir")"
backup_root="$(realpath -e "$K_COMMS_BACKUP_ROOT")"
[[ "$backup_dir" == "${backup_root}/"* ]] ||
  die "backup must be a direct child of ${backup_root}"
[[ "$(dirname "$backup_dir")" == "$backup_root" ]] ||
  die "nested or external backup paths are not accepted"
require_file "${backup_dir}/COMPLETE"
[[ "$(<"${backup_dir}/COMPLETE")" == k-comms-application-backup-v1 ]] ||
  die "backup completion marker is invalid"
require_file "${backup_dir}/SHA256SUMS"
require_file "${backup_dir}/postgres.dump"
require_file "${backup_dir}/minio-data.tar.gz"
(cd "$backup_dir" && sha256sum --check --strict SHA256SUMS)
pg_restore --list "${backup_dir}/postgres.dump" >/dev/null
tar --list --gzip --file "${backup_dir}/minio-data.tar.gz" >/dev/null
acquire_deploy_lock

systemctl stop k-comms-app.service k-comms-minio.service
recovery_failed=true
recover_services() {
  if [[ "$recovery_failed" == true ]]; then
    systemctl start k-comms-minio.service || true
    log "restore failed; application writers remain stopped for operator recovery"
  fi
}
trap recover_services EXIT

postgres_user="$(read_env_value "$K_COMMS_RUNTIME_ENV" POSTGRES_USER)"
postgres_db="$(read_env_value "$K_COMMS_RUNTIME_ENV" POSTGRES_DB)"
[[ "$postgres_user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
  die "POSTGRES_USER contains unsafe characters"
[[ "$postgres_db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
  die "POSTGRES_DB contains unsafe characters"

log "replacing the application database from the verified logical backup"
podman exec k-comms-postgres psql --username "$postgres_user" --dbname postgres \
  --set ON_ERROR_STOP=1 \
  --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${postgres_db}' AND pid <> pg_backend_pid();"
podman exec k-comms-postgres dropdb --if-exists --username "$postgres_user" "$postgres_db"
podman exec k-comms-postgres createdb --username "$postgres_user" "$postgres_db"
podman exec --interactive k-comms-postgres pg_restore \
  --exit-on-error \
  --no-owner \
  --no-privileges \
  --username "$postgres_user" \
  --dbname "$postgres_db" <"${backup_dir}/postgres.dump"

log "replacing the exact managed MinIO volume from the verified snapshot"
minio_path="$(assert_minio_volume_path)"
find "$minio_path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
tar --extract --gzip --numeric-owner \
  --file "${backup_dir}/minio-data.tar.gz" \
  --directory "$minio_path"

if [[ "$restore_runtime" == true ]]; then
  require_file "${backup_dir}/configuration/runtime.env"
  require_file "${backup_dir}/configuration/release.env"
  install -m 0600 "${backup_dir}/configuration/runtime.env" "$K_COMMS_RUNTIME_ENV"
  install -m 0600 "${backup_dir}/configuration/release.env" "$K_COMMS_RELEASE_ENV"
fi

systemctl start k-comms-minio.service
wait_for_url "http://$(configured_bind_address):5900/minio/health/ready" 60 2
systemctl start k-comms-app.service
"${SCRIPT_DIR}/verify.sh" --environment-file "$K_COMMS_ENVIRONMENT_FILE"

recovery_failed=false
trap - EXIT
log "verified backup restore completed from ${backup_dir}"
