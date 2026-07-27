#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
for command in pg_restore podman sha256sum tar; do
  require_command "$command"
done
unit_active k-comms-app.service &&
  die "backup requires application writers to be stopped"
unit_active k-comms-postgres.service ||
  die "PostgreSQL must be active for a logical backup"
unit_active k-comms-minio.service ||
  die "MinIO must be active before the quiesced object snapshot"

revision="$(read_optional_env_value "$K_COMMS_RELEASE_ENV" K_COMMS_RELEASE_REVISION)"
[[ -n "$revision" ]] || revision=unreleased
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${K_COMMS_BACKUP_ROOT}/${timestamp}-${revision}"
[[ ! -e "$backup_dir" ]] || die "backup destination already exists: $backup_dir"
install -d -m 0700 "$backup_dir"

cleanup() {
  if ! unit_active k-comms-minio.service; then
    systemctl start k-comms-minio.service || true
  fi
}
trap cleanup EXIT

log "creating PostgreSQL logical backup"
podman exec k-comms-postgres sh -ceu \
  'pg_dump --format=custom --no-owner --no-privileges --username="$POSTGRES_USER" "$POSTGRES_DB"' \
  >"${backup_dir}/postgres.dump"
pg_restore --list "${backup_dir}/postgres.dump" >/dev/null

log "creating stopped MinIO volume snapshot"
systemctl stop k-comms-minio.service
minio_path="$(assert_minio_volume_path)"
tar --create --gzip --numeric-owner \
  --file "${backup_dir}/minio-data.tar.gz" \
  --directory "$minio_path" .
systemctl start k-comms-minio.service
wait_for_url "http://$(configured_bind_address):5900/minio/health/ready" 60 2

install -d -m 0700 "${backup_dir}/configuration"
install -m 0600 "$K_COMMS_RUNTIME_ENV" "${backup_dir}/configuration/runtime.env"
if [[ -f "$K_COMMS_RELEASE_ENV" ]]; then
  install -m 0600 "$K_COMMS_RELEASE_ENV" "${backup_dir}/configuration/release.env"
fi
cp -a "$K_COMMS_QUADLET_DIR"/k-comms-* "${backup_dir}/configuration/"
install -m 0600 "$K_COMMS_ENVIRONMENT_FILE" "${backup_dir}/configuration/environment"

(
  cd "$backup_dir"
  find . -type f ! -name SHA256SUMS ! -name COMPLETE -print0 |
    sort -z |
    xargs -0 sha256sum >SHA256SUMS
)
install -m 0600 /dev/null "${backup_dir}/COMPLETE"
printf 'k-comms-application-backup-v1\n' >"${backup_dir}/COMPLETE"
chmod -R go-rwx "$backup_dir"

find "$K_COMMS_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +14 \
  -name '*-????????????????????????????????????????' -print0 |
  xargs -0r rm -rf --

trap - EXIT
printf '%s\n' "$backup_dir"
