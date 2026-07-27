#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

environment=
image=
revision=
bootstrap=false
skip_backup=false
livekit_credential=

while (($#)); do
  case "$1" in
    --environment) environment=${2:-}; shift 2 ;;
    --image) image=${2:-}; shift 2 ;;
    --revision) revision=${2:-}; shift 2 ;;
    --bootstrap) bootstrap=true; shift ;;
    --skip-backup) skip_backup=true; shift ;;
    --livekit-credential) livekit_credential=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
for command in curl flock jq podman systemctl; do
  require_command "$command"
done
validate_environment "$environment"
validate_image_ref "$image"
validate_revision "$revision"
assert_secure_runtime_env
[[ "$(configured_environment)" == "$environment" ]] ||
  die "requested environment does not match the installed VM identity"
acquire_deploy_lock
assert_adopted_storage_ready_for_activation

bind_address="$(configured_bind_address)"
validate_ipv4 "$bind_address"
previous_image="$(current_app_image)"
previous_revision="$(current_app_revision)"
previous_capabilities="$(current_app_capabilities)"
previous_image_class="$(classify_image_ref "$previous_image")"
previous_active=false
unit_active k-comms-app.service && previous_active=true

rollback_dir="$(mktemp -d /run/k-comms-deploy.XXXXXX)"
cleanup() {
  rm -rf -- "$rollback_dir"
}
trap cleanup EXIT

if [[ -f "${K_COMMS_QUADLET_DIR}/k-comms-app.container" ]]; then
  cp "${K_COMMS_QUADLET_DIR}/k-comms-app.container" "${rollback_dir}/app.container"
fi
if [[ -f "$K_COMMS_RELEASE_ENV" ]]; then
  cp "$K_COMMS_RELEASE_ENV" "${rollback_dir}/release.env"
fi
cp "$K_COMMS_RUNTIME_ENV" "${rollback_dir}/runtime.env"

runtime_candidate=
if [[ -n "$livekit_credential" ]]; then
  runtime_candidate="${rollback_dir}/runtime.env.candidate"
  write_managed_livekit_runtime_env "$livekit_credential" "$runtime_candidate"
fi

log "pulling immutable application image"
podman pull "$image"
source_label="$(podman image inspect "$image" --format '{{index .Labels "org.opencontainers.image.source"}}')"
revision_label="$(podman image inspect "$image" --format '{{index .Labels "org.opencontainers.image.revision"}}')"
[[ "$source_label" == "$K_COMMS_SOURCE" ]] ||
  die "image source label does not match ${K_COMMS_SOURCE}"
[[ "$revision_label" == "$revision" ]] ||
  die "image revision label does not match the requested commit"

systemctl daemon-reload
systemctl start \
  k-comms-network.service \
  k-comms-postgres.service \
  k-comms-minio.service \
  k-comms-livekit.service
assert_postgres_volume_path >/dev/null
assert_minio_volume_path >/dev/null
wait_for_url "http://${bind_address}:5900/minio/health/ready" 60 2

if [[ "$previous_active" == true ]]; then
  systemctl stop k-comms-app.service
fi

backup_path=
if [[ "$previous_active" == true && "$skip_backup" == false ]]; then
  backup_path="$("${SCRIPT_DIR}/backup.sh")"
fi

release_candidate="${rollback_dir}/release.env.candidate"
write_release_env "$image" "$revision" "$release_candidate"

log "ensuring the versioned object-storage bucket exists"
podman run --rm \
  --network k-comms \
  --env-file "$K_COMMS_RUNTIME_ENV" \
  --entrypoint /bin/sh \
  "$K_COMMS_MINIO_MC_IMAGE" \
  -ceu '
    mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
    mc mb --ignore-existing "local/$S3_BUCKET"
    mc version enable "local/$S3_BUCKET"
    version_info="$(mc version info "local/$S3_BUCKET")"
    case "$version_info" in
      *"versioning is enabled"*) ;;
      *) printf "%s\n" "$version_info" >&2; exit 1 ;;
    esac
  '

run_one_shot() {
  podman run --rm \
    --network k-comms \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=134217728 \
    --cap-drop all \
    --security-opt no-new-privileges \
    --env-file "$K_COMMS_RUNTIME_ENV" \
    --env-file "$release_candidate" \
    "$@"
}

log "running forward-only migrations with application writers stopped"
run_one_shot \
  --env K_COMMS_RUNTIME_PURPOSE=one_shot \
  --env K_COMMS_LOCAL_RELEASE=false \
  --env K_COMMS_RELEASE_EXPOSURE_MODE= \
  --env K_COMMS_TRUSTED_EDGE_CONFIRMATION= \
  --env K_COMMS_MIGRATION_LOCK_TIMEOUT_MS=5000 \
  --env K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS=480000 \
  --env K_COMMS_MIGRATION_REQUIRE_QUIESCENCE=true \
  --env PUBLIC_APP_URL=https://localhost \
  --env AUDIO_PROVIDER_MODE=disabled \
  --env LIVEKIT_SERVER_URL= \
  --env LIVEKIT_API_URL= \
  "$image" eval 'CommsCore.Release.migrate()'

if [[ "$bootstrap" == true ]]; then
  [[ "$environment" == staging ]] ||
    die "bootstrap is allowed only for the synthetic staging environment"
  log "creating the idempotent synthetic staging tenant"
  run_one_shot \
    --env K_COMMS_ROLE=worker \
    --env K_COMMS_RUNTIME_PURPOSE=one_shot \
    --env K_COMMS_LOCAL_RELEASE=false \
    --env K_COMMS_RELEASE_EXPOSURE_MODE= \
    --env K_COMMS_TRUSTED_EDGE_CONFIRMATION= \
    --env ALLOW_BOOTSTRAP=false \
    --env PUBLIC_APP_URL=https://localhost \
    --env AUDIO_PROVIDER_MODE=disabled \
    --env LIVEKIT_SERVER_URL= \
    --env LIVEKIT_API_URL= \
    "$image" eval 'CommsCore.Release.bootstrap()'
fi

render_template \
  "${K_COMMS_TEMPLATE_DIR}/k-comms-app.container.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms-app.container" \
  IMAGE_REF "$image" \
  REVISION "$revision" \
  BIND_ADDRESS "$bind_address"

activation_failed=false
if [[ -n "$runtime_candidate" ]] &&
  ! install -m 0600 "$runtime_candidate" "$K_COMMS_RUNTIME_ENV"; then
  activation_failed=true
elif ! install -m 0600 "$release_candidate" "$K_COMMS_RELEASE_ENV"; then
  activation_failed=true
elif ! systemctl daemon-reload; then
  activation_failed=true
elif ! systemctl start k-comms-app.service; then
  activation_failed=true
elif ! "${SCRIPT_DIR}/verify.sh" --environment "$environment"; then
  activation_failed=true
fi

if [[ "$activation_failed" == true ]]; then
  log "activation failed; restoring the previous application unit"
  systemctl stop k-comms-app.service || true
  install -m 0600 "${rollback_dir}/runtime.env" "$K_COMMS_RUNTIME_ENV"
  if [[ -f "${rollback_dir}/app.container" && -f "${rollback_dir}/release.env" ]]; then
    install -m 0644 "${rollback_dir}/app.container" \
      "${K_COMMS_QUADLET_DIR}/k-comms-app.container"
    install -m 0600 "${rollback_dir}/release.env" "$K_COMMS_RELEASE_ENV"
    systemctl daemon-reload
    systemctl start k-comms-app.service || true
  else
    rm -f "${K_COMMS_QUADLET_DIR}/k-comms-app.container" "$K_COMMS_RELEASE_ENV"
    systemctl daemon-reload
  fi
  die "deployment health gate failed; the previous application unit was restored"
fi

media_topology="$(configured_livekit_topology)"
receipt="${K_COMMS_RECEIPT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-${revision}.json"
jq -n \
  --arg schema k-comms-deployment-receipt-v1 \
  --arg environment "$environment" \
  --arg deployed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg image "$image" \
  --arg revision "$revision" \
  --arg capabilities "$K_COMMS_CAPABILITIES" \
  --arg previous_image "$previous_image" \
  --arg previous_revision "$previous_revision" \
  --arg previous_capabilities "$previous_capabilities" \
  --arg previous_image_class "$previous_image_class" \
  --arg backup_path "$backup_path" \
  --arg media_topology "$media_topology" \
  '{
    schema: $schema,
    environment: $environment,
    deployed_at: $deployed_at,
    image: $image,
    revision: $revision,
    rollback_capabilities: $capabilities,
    previous: {
      image: $previous_image,
      revision: $previous_revision,
      rollback_capabilities: $previous_capabilities,
      image_class: $previous_image_class
    },
    backup_path: $backup_path,
    media_topology: $media_topology
  }' >"$receipt"
chmod 0600 "$receipt"
ln -sfn "$(basename "$receipt")" "${K_COMMS_RECEIPT_DIR}/current.json"

systemctl enable --now k-comms-health.timer k-comms-backup.timer
trap - EXIT
cleanup
log "deployment completed: ${image}"
log "receipt: ${receipt}"
