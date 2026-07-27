#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

runtime_source=
confirmation=
preflight_only=false
legacy_service=k-comms.service
legacy_app=k-comms-release_app_1
legacy_postgres=k-comms-release_postgres_1
legacy_minio=k-comms-release_minio_1
legacy_livekit=k-comms-release_livekit_1
postgres_volume=k-comms-release_postgres-data
minio_volume=k-comms-release_minio-data

while (($#)); do
  case "$1" in
    --runtime-source) runtime_source=${2:-}; shift 2 ;;
    --confirmation) confirmation=${2:-}; shift 2 ;;
    --preflight-only) preflight_only=true; shift ;;
    --legacy-service) legacy_service=${2:-}; shift 2 ;;
    --legacy-app) legacy_app=${2:-}; shift 2 ;;
    --legacy-postgres) legacy_postgres=${2:-}; shift 2 ;;
    --legacy-minio) legacy_minio=${2:-}; shift 2 ;;
    --legacy-livekit) legacy_livekit=${2:-}; shift 2 ;;
    --postgres-volume) postgres_volume=${2:-}; shift 2 ;;
    --minio-volume) minio_volume=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
[[ "$confirmation" == adopt-k-comms-production-v1 ]] ||
  die "adoption requires --confirmation adopt-k-comms-production-v1"
[[ -n "$runtime_source" ]] || die "--runtime-source is required"
runtime_source="$(realpath -e "$runtime_source")"
for command in curl flock ip jq podman sha256sum systemctl tar; do
  require_command "$command"
done
validate_volume_name "$postgres_volume"
validate_volume_name "$minio_volume"
[[ "$postgres_volume" != "$minio_volume" ]] ||
  die "PostgreSQL and MinIO must use different volumes"
[[ "$(stat -c '%a' "$runtime_source")" == 600 ]] ||
  die "legacy runtime source must have mode 0600"
[[ "$(stat -c '%u' "$runtime_source")" == 0 ]] ||
  die "legacy runtime source must be owned by root"
! grep -q 'CHANGE_ME' "$runtime_source" ||
  die "legacy runtime source contains a placeholder"
[[ ! -e "${K_COMMS_RECEIPT_DIR}/legacy-adoption.json" ]] ||
  die "legacy production has already been adopted"

for name in \
  POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DATABASE_URL SECRET_KEY_BASE \
  PASSWORD_RECOVERY_SIGNING_KEY WEBHOOK_SECRET_ENCRYPTION_KEY \
  PUSH_SUBSCRIPTION_ENCRYPTION_KEY METRICS_BEARER_TOKEN PUBLIC_APP_URL \
  CORS_ORIGINS CSP_CONNECT_SOURCES LIVEKIT_API_KEY LIVEKIT_API_SECRET \
  MINIO_ROOT_USER MINIO_ROOT_PASSWORD S3_BUCKET; do
  read_env_value "$runtime_source" "$name" >/dev/null
done

for container in \
  "$legacy_app" "$legacy_postgres" "$legacy_minio" "$legacy_livekit"; do
  container_exists "$container" ||
    die "legacy container is missing: ${container}"
  [[ "$(podman inspect "$container" --format '{{.State.Running}}')" == true ]] ||
    die "legacy container is not running: ${container}"
done
for container in "$legacy_app" "$legacy_postgres" "$legacy_minio"; do
  [[ "$(podman inspect "$container" --format '{{.State.Health.Status}}')" == healthy ]] ||
    die "legacy container is not healthy: ${container}"
done
unit_active "$legacy_service" ||
  die "legacy production service is not active: ${legacy_service}"

assert_legacy_mount() {
  local container=$1
  local volume=$2
  local destination=$3
  local mounts

  mounts="$(podman inspect "$container" \
    --format '{{range .Mounts}}{{.Name}}:{{.Destination}};{{end}}')"
  [[ "$mounts" == *"${volume}:${destination};"* ]] ||
    die "${container} does not mount ${volume} at ${destination}"
}

assert_legacy_mount "$legacy_postgres" "$postgres_volume" /var/lib/postgresql/data
assert_legacy_mount "$legacy_minio" "$minio_volume" /data
postgres_path="$(assert_volume_path "$postgres_volume")"
minio_path="$(assert_volume_path "$minio_volume")"
[[ -f "${postgres_path}/PG_VERSION" ]] ||
  die "legacy PostgreSQL volume is missing PG_VERSION"
[[ -f "${minio_path}/.minio.sys/format.json" ]] ||
  die "legacy MinIO volume is missing its format marker"

current_image="$(podman inspect "$legacy_app" --format '{{.ImageName}}')"
current_revision="$(podman inspect "$legacy_app" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
current_source="$(podman inspect "$legacy_app" \
  --format '{{index .Config.Labels "org.opencontainers.image.source"}}')"
validate_adopted_local_image_ref "$current_image"
validate_revision "$current_revision"
[[ "$current_source" == "$K_COMMS_SOURCE" ]] ||
  die "legacy application source label does not match ${K_COMMS_SOURCE}"
podman image exists "$current_image" ||
  die "legacy application image is not present locally"

if podman network exists k-comms; then
  existing_subnet="$(podman network inspect k-comms \
    --format '{{range .Subnets}}{{.Subnet}}{{end}}')"
  [[ "$existing_subnet" == 10.90.0.0/24 ]] ||
    die "managed network k-comms exists with unexpected subnet ${existing_subnet}"
elif ip -4 route show | grep -q -E '(^| )10\.90\.0\.0/24( |$)'; then
  die "dedicated production Podman subnet 10.90.0.0/24 is already in use"
fi

if [[ "$preflight_only" == true ]]; then
  log "legacy production adoption preflight passed without changing the VM"
  exit 0
fi

runtime_candidate="$(mktemp /run/k-comms-runtime.XXXXXX)"
cleanup_runtime_candidate() {
  rm -f -- "$runtime_candidate"
}
trap cleanup_runtime_candidate EXIT
grep -Ev \
  '^(K_COMMS_RELEASE_IMAGE|K_COMMS_RELEASE_REVISION|K_COMMS_RELEASE_VERSION|K_COMMS_RELEASE_PROJECT)=' \
  "$runtime_source" >"$runtime_candidate"

append_env_if_missing() {
  local name=$1
  local value=$2

  if ! grep -q -E "^${name}=" "$runtime_candidate"; then
    printf '%s=%s\n' "$name" "$value" >>"$runtime_candidate"
  fi
}

append_env_if_missing PORT 4000
append_env_if_missing ALLOW_DEVELOPMENT_ADAPTERS true
append_env_if_missing NOTIFICATION_PROVIDER_MODE log
append_env_if_missing NOTIFICATION_PROVIDER_NAME proxmox-release-log
append_env_if_missing ATTACHMENT_SCANNER_MODE allow_all
append_env_if_missing ATTACHMENT_SCANNER_PROVIDER_NAME proxmox-release-allow-all
append_env_if_missing WEBHOOK_PROVIDER_MODE log
append_env_if_missing WEBHOOK_ALLOWED_HOSTS webhook.local
append_env_if_missing WEBHOOK_SECRET_ENCRYPTION_KEY_ID primary
append_env_if_missing PUSH_SUBSCRIPTION_ENCRYPTION_KEY_ID primary
append_env_if_missing METRICS_ALLOW_UNAUTHENTICATED false
append_env_if_missing AUDIO_PROVIDER_MODE livekit
append_env_if_missing AUDIO_TOKEN_TTL_SECONDS 300
append_env_if_missing AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS 660
append_env_if_missing LIVEKIT_API_URL http://livekit:7880
append_env_if_missing LIVEKIT_KEYS \
  "$(read_env_value "$runtime_source" LIVEKIT_API_KEY): $(read_env_value "$runtime_source" LIVEKIT_API_SECRET)"
append_env_if_missing S3_INTERNAL_ENDPOINT http://minio:9000
append_env_if_missing S3_REGION us-east-1
append_env_if_missing S3_ACCESS_KEY_ID \
  "$(read_env_value "$runtime_source" MINIO_ROOT_USER)"
append_env_if_missing S3_SECRET_ACCESS_KEY \
  "$(read_env_value "$runtime_source" MINIO_ROOT_PASSWORD)"

if [[ -e "$K_COMMS_RUNTIME_ENV" ]]; then
  assert_secure_runtime_env
  if [[ -e "$K_COMMS_ENVIRONMENT_FILE" ]]; then
    [[ "$(configured_environment)" == production ]] ||
      die "existing prepared runtime is not bound to production"
    [[ "$(configured_storage_mode)" == adopted ]] ||
      die "existing prepared runtime does not use adopted storage"
    [[ "$(configured_postgres_volume)" == "$postgres_volume" ]] ||
      die "existing prepared PostgreSQL volume does not match the adoption request"
    [[ "$(configured_minio_volume)" == "$minio_volume" ]] ||
      die "existing prepared MinIO volume does not match the adoption request"
    existing_network_subnet="$(
      read_optional_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_NETWORK_SUBNET
    )"
    if [[ -n "$existing_network_subnet" ]]; then
      [[ "$existing_network_subnet" == 10.90.0.0/24 ]] ||
        die "existing prepared production network uses an unexpected subnet"
    fi
  fi
  for name in POSTGRES_PASSWORD LIVEKIT_API_SECRET MINIO_ROOT_PASSWORD; do
    [[ "$(read_env_value "$K_COMMS_RUNTIME_ENV" "$name")" == \
      "$(read_env_value "$runtime_source" "$name")" ]] ||
      die "existing prepared runtime does not match legacy credential ${name}"
  done
else
  install -d -m 0750 "$K_COMMS_CONFIG_DIR"
  install -m 0600 "$runtime_candidate" "$K_COMMS_RUNTIME_ENV"
  assert_secure_runtime_env
fi

bash "${SCRIPT_DIR}/install.sh" \
  --environment production \
  --bind-address 127.0.0.1 \
  --media-address 192.168.1.22 \
  --storage-mode adopted \
  --network-subnet 10.90.0.0/24 \
  --network-gateway 10.90.0.1 \
  --postgres-volume "$postgres_volume" \
  --minio-volume "$minio_volume" \
  --prepare-only
require_command pg_restore

write_release_env "$current_image" "$current_revision" "$K_COMMS_RELEASE_ENV"
render_template \
  "${K_COMMS_TEMPLATE_DIR}/k-comms-app.container.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms-app.container" \
  IMAGE_REF "$current_image" \
  REVISION "$current_revision" \
  BIND_ADDRESS 127.0.0.1
systemctl daemon-reload
acquire_deploy_lock

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${K_COMMS_BACKUP_ROOT}/${timestamp}-${current_revision}"
[[ ! -e "$backup_dir" ]] || die "backup destination already exists: $backup_dir"
install -d -m 0700 "$backup_dir"

cutover_started=false
adoption_complete=false
recover_legacy() {
  if [[ "$cutover_started" == true && "$adoption_complete" == false ]]; then
    log "adoption failed; restoring the retained legacy service"
    systemctl disable --now k-comms-health.timer k-comms-backup.timer || true
    systemctl stop \
      k-comms-app.service \
      k-comms-livekit.service \
      k-comms-minio.service \
      k-comms-postgres.service \
      k-comms-network.service || true
    systemctl enable "$legacy_service" || true
    systemctl restart "$legacy_service" || true
  fi
  cleanup_runtime_candidate
}
trap recover_legacy EXIT

log "stopping legacy application writers"
podman stop --time 30 "$legacy_app" >/dev/null
cutover_started=true

log "creating the one-time PostgreSQL adoption backup"
podman exec "$legacy_postgres" sh -ceu \
  'pg_dump --format=custom --no-owner --no-privileges --username="$POSTGRES_USER" "$POSTGRES_DB"' \
  >"${backup_dir}/postgres.dump"
pg_restore --list "${backup_dir}/postgres.dump" >/dev/null

log "creating the stopped MinIO adoption snapshot"
podman stop --time 30 "$legacy_minio" >/dev/null
tar --create --gzip --numeric-owner \
  --file "${backup_dir}/minio-data.tar.gz" \
  --directory "$minio_path" .

systemctl disable --now "$legacy_service"
for container in \
  "$legacy_app" "$legacy_postgres" "$legacy_minio" "$legacy_livekit"; do
  [[ "$(podman inspect "$container" --format '{{.State.Running}}')" == false ]] ||
    die "legacy container remained active after shutdown: ${container}"
done

install -d -m 0700 "${backup_dir}/configuration"
install -m 0600 "$K_COMMS_RUNTIME_ENV" "${backup_dir}/configuration/runtime.env"
install -m 0600 "$K_COMMS_RELEASE_ENV" "${backup_dir}/configuration/release.env"
install -m 0600 "$K_COMMS_ENVIRONMENT_FILE" \
  "${backup_dir}/configuration/environment"
cp -a "$K_COMMS_QUADLET_DIR"/k-comms-* "${backup_dir}/configuration/"
(
  cd "$backup_dir"
  find . -type f ! -name SHA256SUMS ! -name COMPLETE -print0 |
    sort -z |
    xargs -0 sha256sum >SHA256SUMS
)
install -m 0600 /dev/null "${backup_dir}/COMPLETE"
printf 'k-comms-application-backup-v1\n' >"${backup_dir}/COMPLETE"
chmod -R go-rwx "$backup_dir"

assert_adopted_storage_ready_for_activation
systemctl start \
  k-comms-network.service \
  k-comms-postgres.service \
  k-comms-minio.service \
  k-comms-livekit.service \
  k-comms-app.service
bash "${SCRIPT_DIR}/verify.sh" --environment production

bash "${SCRIPT_DIR}/install.sh" \
  --environment production \
  --bind-address 127.0.0.1 \
  --media-address 192.168.1.22 \
  --storage-mode adopted \
  --network-subnet 10.90.0.0/24 \
  --network-gateway 10.90.0.1 \
  --postgres-volume "$postgres_volume" \
  --minio-volume "$minio_volume"
bash "${SCRIPT_DIR}/sync-assets.sh"
bash "${SCRIPT_DIR}/verify.sh" --environment production

receipt="${K_COMMS_RECEIPT_DIR}/${timestamp}-legacy-adoption.json"
jq -n \
  --arg schema k-comms-legacy-adoption-receipt-v1 \
  --arg adopted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg image "$current_image" \
  --arg revision "$current_revision" \
  --arg postgres_volume "$postgres_volume" \
  --arg minio_volume "$minio_volume" \
  --arg backup_path "$backup_dir" \
  '{
    schema: $schema,
    environment: "production",
    adopted_at: $adopted_at,
    image: $image,
    revision: $revision,
    image_class: "adopted-local",
    storage: {
      mode: "adopted",
      postgres_volume: $postgres_volume,
      minio_volume: $minio_volume
    },
    backup_path: $backup_path
  }' >"$receipt"
chmod 0600 "$receipt"
ln -sfn "$(basename "$receipt")" "${K_COMMS_RECEIPT_DIR}/current.json"
ln -sfn "$(basename "$receipt")" "${K_COMMS_RECEIPT_DIR}/legacy-adoption.json"

adoption_complete=true
trap - EXIT
cleanup_runtime_candidate
log "legacy production adoption completed without changing application identity"
log "receipt: ${receipt}"
log "backup: ${backup_dir}"
