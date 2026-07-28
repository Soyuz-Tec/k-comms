#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

environment_file=$K_COMMS_ENVIRONMENT_FILE
environment=
skip_host_tuning=false
require_pwa=false

while (($#)); do
  case "$1" in
    --environment-file) environment_file=${2:-}; shift 2 ;;
    --environment) environment=${2:-}; shift 2 ;;
    --skip-host-tuning) skip_host_tuning=true; shift ;;
    --require-pwa) require_pwa=true; shift ;;
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
pwa_capability="$(
  podman image inspect "$actual_image" \
    --format '{{index .Labels "io.k-comms.pwa"}}'
)"
[[ "$actual_image" == "$release_image" ]] ||
  die "running image does not match the release identity"
[[ "$actual_revision" == "$release_revision" ]] ||
  die "running revision does not match the release identity"

if [[ "$require_pwa" == true && "$pwa_capability" != 1 ]]; then
  die "PWA verification was required but the running image lacks io.k-comms.pwa=1"
fi

if [[ "$pwa_capability" == 1 ]]; then
  pwa_origin="http://${bind_address}:4188/app"
  worker_url="${pwa_origin}/k-comms-sw.js?revision=${release_revision}"
  worker_headers="$(curl --fail --silent --show-error --max-time 10 \
    --dump-header - --output /dev/null "$worker_url" | tr -d '\r')"
  grep -Fqx "cache-control: no-store, max-age=0, must-revalidate" \
    <<<"${worker_headers,,}" ||
    die "PWA service worker cache policy is unsafe"
  grep -Fqx "service-worker-allowed: /app/" <<<"${worker_headers,,}" ||
    die "PWA service worker scope header is missing"
  worker_body="$(curl --fail --silent --show-error --max-time 10 "$worker_url")"
  grep -Fq "$release_revision" <<<"$worker_body" ||
    die "PWA service worker does not identify the running release revision"

  manifest_headers="$(curl --fail --silent --show-error --max-time 10 \
    --dump-header - --output /dev/null "${pwa_origin}/manifest.webmanifest" | tr -d '\r')"
  grep -Fqx "cache-control: no-cache, max-age=0, must-revalidate" \
    <<<"${manifest_headers,,}" ||
    die "PWA manifest cache policy is unsafe"
  grep -Eq '^content-type: application/manifest\+json' <<<"${manifest_headers,,}" ||
    die "PWA manifest content type is invalid"
  manifest_body="$(curl --fail --silent --show-error --max-time 10 \
    "${pwa_origin}/manifest.webmanifest")"
  grep -Fq '"start_url": "/app/"' <<<"$manifest_body" ||
    die "PWA manifest start URL is invalid"
  offline_body="$(curl --fail --silent --show-error --max-time 10 \
    "${pwa_origin}/offline.html")"
  grep -Fq "K-Comms is offline" <<<"$offline_body" ||
    die "PWA offline fallback is unavailable"

  app_index_headers="$(curl --fail --silent --show-error --max-time 10 \
    --dump-header - --output /dev/null "${pwa_origin}/" | tr -d '\r')"
  grep -Fqx "cache-control: no-store, max-age=0, must-revalidate" \
    <<<"${app_index_headers,,}" ||
    die "PWA application entry cache policy is unsafe"
  app_index="$(curl --fail --silent --show-error --max-time 10 "${pwa_origin}/")"
  hashed_asset_path="$(
    grep -Eo '/app/assets/[^"[:space:]]+\.js' \
      <<<"$app_index" |
      head -n 1 ||
      true
  )"
  [[ -n "$hashed_asset_path" ]] ||
    die "PWA application index has no revisioned JavaScript bundle"
  grep -Eq \
    '^/app/assets/[A-Za-z0-9._-]+-[A-Za-z0-9_-]{8,}\.js$' \
    <<<"$hashed_asset_path" ||
    die "PWA application bundle is not content-revisioned"
  hashed_asset_headers="$(curl --fail --silent --show-error --max-time 10 \
    --dump-header - --output /dev/null \
    "http://${bind_address}:4188${hashed_asset_path}" | tr -d '\r')"
  grep -Fqx "cache-control: public, max-age=31536000, immutable" \
    <<<"${hashed_asset_headers,,}" ||
    die "PWA hashed asset cache policy is unsafe"
  hashed_asset_content_type="$(
    grep -i '^content-type:' <<<"$hashed_asset_headers" |
      head -n 1 ||
      true
  )"
  hashed_asset_content_type="${hashed_asset_content_type#*: }"
  hashed_asset_mime="${hashed_asset_content_type%%;*}"
  [[ "${hashed_asset_mime,,}" == text/javascript ]] ||
    die "PWA hashed asset content type is invalid"

  missing_asset_path="/app/assets/missing-${release_revision:0:12}.js"
  missing_asset_url="http://${bind_address}:4188${missing_asset_path}"
  missing_asset_status="$(curl --silent --show-error --max-time 10 \
    --output /dev/null --write-out '%{http_code}' "$missing_asset_url")"
  [[ "$missing_asset_status" == 404 ]] ||
    die "PWA missing hash-shaped asset did not return HTTP 404"
  missing_asset_headers="$(curl --silent --show-error --max-time 10 \
    --dump-header - --output /dev/null "$missing_asset_url" | tr -d '\r')"
  grep -Fqx "cache-control: no-store, max-age=0, must-revalidate" \
    <<<"${missing_asset_headers,,}" ||
    die "PWA missing hash-shaped asset cache policy is unsafe"
  missing_asset_content_type="$(
    grep -i '^content-type:' <<<"$missing_asset_headers" |
      head -n 1 ||
      true
  )"
  missing_asset_content_type="${missing_asset_content_type#*: }"
  missing_asset_mime="${missing_asset_content_type%%;*}"
  [[ "${missing_asset_mime,,}" == text/plain ]] ||
    die "PWA missing hash-shaped asset content type is invalid"
else
  log "running image has no PWA capability label; skipping PWA asset checks"
fi

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
