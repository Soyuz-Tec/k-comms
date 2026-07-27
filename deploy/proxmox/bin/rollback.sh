#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

receipt="${K_COMMS_RECEIPT_DIR}/current.json"

while (($#)); do
  case "$1" in
    --receipt) receipt=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
for command in jq podman systemctl; do
  require_command "$command"
done
require_file "$receipt"
acquire_deploy_lock
rollback_guard_dir="$(mktemp -d /run/k-comms-rollback.XXXXXX)"
cp "${K_COMMS_QUADLET_DIR}/k-comms-app.container" \
  "${rollback_guard_dir}/app.container"
cp "$K_COMMS_RELEASE_ENV" "${rollback_guard_dir}/release.env"
rollback_complete=false

recover_current() {
  if [[ "$rollback_complete" == false ]]; then
    log "rollback failed; restoring the pre-rollback application identity"
    systemctl stop k-comms-app.service || true
    install -m 0644 "${rollback_guard_dir}/app.container" \
      "${K_COMMS_QUADLET_DIR}/k-comms-app.container"
    install -m 0600 "${rollback_guard_dir}/release.env" "$K_COMMS_RELEASE_ENV"
    systemctl daemon-reload
    systemctl start k-comms-app.service || true
  fi
  rm -rf -- "$rollback_guard_dir"
}
trap recover_current EXIT

[[ "$(jq -r '.schema' "$receipt")" == k-comms-deployment-receipt-v1 ]] ||
  die "unsupported deployment receipt"
environment="$(jq -r '.environment' "$receipt")"
current_image="$(jq -r '.image' "$receipt")"
target_image="$(jq -r '.previous.image' "$receipt")"
target_revision="$(jq -r '.previous.revision' "$receipt")"
target_capabilities="$(jq -r '.previous.rollback_capabilities // ""' "$receipt")"
target_image_class="$(jq -r '.previous.image_class // "immutable-ghcr"' "$receipt")"
validate_environment "$environment"
validate_image_ref "$current_image"
validate_revision "$target_revision"
case "$target_image_class" in
  immutable-ghcr)
    validate_image_ref "$target_image"
    podman image exists "$target_image" || podman pull "$target_image"
    ;;
  adopted-local)
    validate_adopted_local_image_ref "$target_image"
    podman image exists "$target_image" ||
      die "the one-time adopted rollback image is no longer present locally"
    ;;
  *)
    die "unsupported rollback image class: ${target_image_class}"
    ;;
esac
[[ "$(current_app_image)" == "$current_image" ]] ||
  die "receipt does not describe the currently running image"

podman image exists "$current_image" || podman pull "$current_image"
target_source="$(podman image inspect "$target_image" \
  --format '{{index .Labels "org.opencontainers.image.source"}}')"
target_label_revision="$(podman image inspect "$target_image" \
  --format '{{index .Labels "org.opencontainers.image.revision"}}')"
[[ "$target_source" == "$K_COMMS_SOURCE" && "$target_label_revision" == "$target_revision" ]] ||
  die "rollback target labels do not match the approved repository and revision"

systemctl stop k-comms-app.service

backup_path="$("${SCRIPT_DIR}/backup.sh")"

log "running communication rollback compatibility preflight"
podman run --rm \
  --network k-comms \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=134217728 \
  --cap-drop all \
  --security-opt no-new-privileges \
  --env-file "$K_COMMS_RUNTIME_ENV" \
  --env-file "$K_COMMS_RELEASE_ENV" \
  --env K_COMMS_ROLE=worker \
  --env K_COMMS_RUNTIME_PURPOSE=one_shot \
  --env K_COMMS_LOCAL_RELEASE=false \
  --env K_COMMS_RELEASE_EXPOSURE_MODE= \
  --env K_COMMS_TRUSTED_EDGE_CONFIRMATION= \
  --env K_COMMS_ROLLBACK_TARGET_CAPABILITIES="$target_capabilities" \
  --env K_COMMS_ROLLBACK_TARGET_REVISION="$target_revision" \
  --env K_COMMS_ROLLBACK_WRITES_QUIESCED=true \
  --env PUBLIC_APP_URL=https://localhost \
  --env AUDIO_PROVIDER_MODE=disabled \
  --env LIVEKIT_SERVER_URL= \
  --env LIVEKIT_API_URL= \
  "$current_image" eval 'CommsCore.Release.assert_communication_rollback_compatible!()'

bind_address="$(configured_bind_address)"
render_template \
  "${K_COMMS_TEMPLATE_DIR}/k-comms-app.container.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms-app.container" \
  IMAGE_REF "$target_image" \
  REVISION "$target_revision" \
  BIND_ADDRESS "$bind_address"
write_release_env "$target_image" "$target_revision" "$K_COMMS_RELEASE_ENV"
systemctl daemon-reload
systemctl start k-comms-app.service
"${SCRIPT_DIR}/verify.sh" --environment "$environment"

rollback_receipt="${K_COMMS_RECEIPT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-rollback-${target_revision}.json"
jq -n \
  --arg schema k-comms-rollback-receipt-v1 \
  --arg environment "$environment" \
  --arg rolled_back_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg from_image "$current_image" \
  --arg to_image "$target_image" \
  --arg to_revision "$target_revision" \
  --arg backup_path "$backup_path" \
  '{
    schema: $schema,
    environment: $environment,
    rolled_back_at: $rolled_back_at,
    from_image: $from_image,
    to_image: $to_image,
    to_revision: $to_revision,
    backup_path: $backup_path
  }' >"$rollback_receipt"
chmod 0600 "$rollback_receipt"

rollback_complete=true
trap - EXIT
rm -rf -- "$rollback_guard_dir"
log "rollback completed without a down migration"
log "receipt: ${rollback_receipt}"
