#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

environment_file=$K_COMMS_ENVIRONMENT_FILE
environment=
skip_host_tuning=false

while (($#)); do
  case "$1" in
    --environment-file) environment_file=${2:-}; shift 2 ;;
    --environment) environment=${2:-}; shift 2 ;;
    --skip-host-tuning) skip_host_tuning=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
for command in curl podman sysctl systemctl; do
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

assert_managed_livekit_runtime
livekit_topology="$(configured_livekit_topology)"
if [[ "$livekit_topology" == "$K_COMMS_MANAGED_LIVEKIT_TOPOLOGY" ]]; then
  managed_livekit_api_url="$(read_env_value "$K_COMMS_RUNTIME_ENV" LIVEKIT_API_URL)"
  curl --fail --silent --show-error --max-time 10 \
    "${managed_livekit_api_url}/" >/dev/null ||
    die "managed LiveKit Cloud endpoint is not reachable"
fi

release_image="$(read_env_value "$K_COMMS_RELEASE_ENV" K_COMMS_RELEASE_IMAGE)"
release_revision="$(read_env_value "$K_COMMS_RELEASE_ENV" K_COMMS_RELEASE_REVISION)"
validate_revision "$release_revision"
release_image_class="$(classify_image_ref "$release_image")"
case "$release_image_class" in
  immutable-ghcr)
    validate_image_ref "$release_image"
    ;;
  adopted-local)
    [[ "$environment" == production ]] ||
      die "an adopted local image is accepted only in production"
    [[ "$(configured_storage_mode)" == adopted ]] ||
      die "an adopted local image requires the adopted storage identity"
    validate_adopted_local_image_ref "$release_image"
    adopted_source="$(podman image inspect "$release_image" \
      --format '{{index .Labels "org.opencontainers.image.source"}}')"
    adopted_revision="$(podman image inspect "$release_image" \
      --format '{{index .Labels "org.opencontainers.image.revision"}}')"
    [[ "$adopted_source" == "$K_COMMS_SOURCE" ]] ||
      die "adopted local image source label does not match ${K_COMMS_SOURCE}"
    [[ "$adopted_revision" == "$release_revision" ]] ||
      die "adopted local image revision label does not match the release identity"
    ;;
  *)
    die "unsupported release image identity: ${release_image}"
    ;;
esac

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

if [[ "$skip_host_tuning" == false ]]; then
  receive_buffer_max="$(sysctl -n net.core.rmem_max)"
  [[ "$receive_buffer_max" =~ ^[0-9]+$ && "$receive_buffer_max" -ge 5000000 ]] ||
    die "LiveKit UDP receive-buffer ceiling is below 5000000 bytes"
fi

log "${environment} verification passed for ${release_image} with ${livekit_topology} media"
