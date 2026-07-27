#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

environment_file=$K_COMMS_ENVIRONMENT_FILE
environment=

while (($#)); do
  case "$1" in
    --environment-file) environment_file=${2:-}; shift 2 ;;
    --environment) environment=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
for command in curl podman systemctl; do
  require_command "$command"
done

if [[ -z "$environment" ]]; then
  environment="$(read_env_value "$environment_file" K_COMMS_ENVIRONMENT)"
fi
validate_environment "$environment"
bind_address="$(read_env_value "$environment_file" K_COMMS_BIND_ADDRESS)"
validate_ipv4 "$bind_address"

for unit in \
  k-comms-postgres.service \
  k-comms-minio.service \
  k-comms-livekit.service \
  k-comms-app.service; do
  unit_active "$unit" || die "required unit is not active: $unit"
done

for container in k-comms-postgres k-comms-minio k-comms-livekit k-comms-app; do
  container_exists "$container" || die "required container is missing: $container"
  [[ "$(podman inspect "$container" --format '{{.State.Running}}')" == true ]] ||
    die "container is not running: $container"
done

for container in k-comms-postgres k-comms-minio k-comms-app; do
  [[ "$(podman inspect "$container" --format '{{.State.Health.Status}}')" == healthy ]] ||
    die "container is not healthy: $container"
done

assert_postgres_volume_path >/dev/null
assert_minio_volume_path >/dev/null
assert_adopted_storage_ready_for_activation

wait_for_url "http://${bind_address}:4188/health/ready" 3 1
wait_for_url "http://${bind_address}:5900/minio/health/ready" 3 1
curl --silent --show-error --max-time 5 "http://${bind_address}:7980/" >/dev/null ||
  die "LiveKit signaling port is not reachable"

release_image="$(read_env_value "$K_COMMS_RELEASE_ENV" K_COMMS_RELEASE_IMAGE)"
release_revision="$(read_env_value "$K_COMMS_RELEASE_ENV" K_COMMS_RELEASE_REVISION)"
validate_image_ref "$release_image"
validate_revision "$release_revision"

actual_image="$(podman inspect k-comms-app --format '{{.ImageName}}')"
actual_revision="$(podman inspect k-comms-app --format '{{index .Config.Labels "io.k-comms.revision"}}')"
[[ "$actual_image" == "$release_image" ]] ||
  die "running image does not match the release identity"
[[ "$actual_revision" == "$release_revision" ]] ||
  die "running revision does not match the release identity"

if [[ "$environment" == production ]] && systemctl list-unit-files cloudflared-kcomms.service \
  --no-legend 2>/dev/null | grep -q '^cloudflared-kcomms.service'; then
  unit_active cloudflared-kcomms.service ||
    die "production Cloudflare Tunnel service is installed but inactive"
fi

log "${environment} verification passed for ${release_image}"
