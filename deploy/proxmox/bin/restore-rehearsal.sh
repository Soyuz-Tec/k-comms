#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

backup_dir=

while (($#)); do
  case "$1" in
    --backup) backup_dir=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
for command in jq pg_restore podman sha256sum tar; do
  require_command "$command"
done
[[ "$(configured_environment)" == staging ]] ||
  die "isolated restore rehearsal is permitted only in staging"
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
(cd "$backup_dir" && sha256sum --check --strict SHA256SUMS) >&2
pg_restore --list "${backup_dir}/postgres.dump" >/dev/null
tar --list --gzip --file "${backup_dir}/minio-data.tar.gz" >/dev/null
acquire_deploy_lock

postgres_user="$(read_env_value "$K_COMMS_RUNTIME_ENV" POSTGRES_USER)"
[[ "$postgres_user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
  die "POSTGRES_USER contains unsafe characters"
rehearsal_database="k_comms_restore_$(date -u +%Y%m%d%H%M%S)_${BASHPID}"
[[ "$rehearsal_database" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
  die "generated rehearsal database name is unsafe"

restore_root="$(mktemp -d "${K_COMMS_BACKUP_ROOT}/restore-rehearsal.XXXXXX")"
database_created=false
cleanup() {
  if [[ "$database_created" == true ]]; then
    podman exec k-comms-postgres dropdb \
      --if-exists \
      --username "$postgres_user" \
      "$rehearsal_database" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$restore_root"
}
trap cleanup EXIT

log "restoring PostgreSQL into an isolated staging rehearsal database"
podman exec k-comms-postgres createdb \
  --username "$postgres_user" \
  "$rehearsal_database"
database_created=true
podman exec --interactive k-comms-postgres pg_restore \
  --exit-on-error \
  --no-owner \
  --no-privileges \
  --username "$postgres_user" \
  --dbname "$rehearsal_database" <"${backup_dir}/postgres.dump"
table_count="$(
  podman exec k-comms-postgres psql \
    --username "$postgres_user" \
    --dbname "$rehearsal_database" \
    --tuples-only \
    --no-align \
    --command "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';"
)"
[[ "$table_count" =~ ^[0-9]+$ ]] ||
  die "restored PostgreSQL table count is invalid"

log "extracting the MinIO snapshot into an isolated staging rehearsal directory"
tar --extract --gzip --numeric-owner \
  --file "${backup_dir}/minio-data.tar.gz" \
  --directory "$restore_root"
require_file "${restore_root}/.minio.sys/format.json"
object_entry_count="$(
  find "$restore_root" -mindepth 1 -print | wc -l | tr -d '[:space:]'
)"
[[ "$object_entry_count" =~ ^[0-9]+$ ]] ||
  die "restored MinIO entry count is invalid"

receipt="$(
  printf '%s/%s-restore-rehearsal.json' \
    "$K_COMMS_RECEIPT_DIR" \
    "$(date -u +%Y%m%dT%H%M%SZ)"
)"
jq -n \
  --arg schema k-comms-restore-rehearsal-receipt-v1 \
  --arg environment staging \
  --arg rehearsed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg backup_path "$backup_dir" \
  --arg backup_manifest_sha256 "$(
    sha256sum "${backup_dir}/SHA256SUMS" | cut -d' ' -f1
  )" \
  --argjson postgres_public_tables "$table_count" \
  --argjson minio_archive_entries "$object_entry_count" \
  '{
    schema: $schema,
    environment: $environment,
    rehearsed_at: $rehearsed_at,
    backup_path: $backup_path,
    backup_manifest_sha256: $backup_manifest_sha256,
    postgres_public_tables: $postgres_public_tables,
    minio_archive_entries: $minio_archive_entries
  }' >"$receipt"
chmod 0600 "$receipt"
ln -sfn "$(basename "$receipt")" \
  "${K_COMMS_RECEIPT_DIR}/latest-restore-rehearsal.json"

podman exec k-comms-postgres dropdb \
  --username "$postgres_user" \
  "$rehearsal_database"
database_created=false
rm -rf -- "$restore_root"
trap - EXIT
log "isolated staging restore rehearsal passed"
printf '%s\n' "$receipt"
