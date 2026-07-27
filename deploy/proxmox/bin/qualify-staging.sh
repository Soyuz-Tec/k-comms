#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

image=
revision=

while (($#)); do
  case "$1" in
    --image) image=${2:-}; shift 2 ;;
    --revision) revision=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
for command in jq readlink; do
  require_command "$command"
done
validate_image_ref "$image"
validate_revision "$revision"
[[ "$(configured_environment)" == staging ]] ||
  die "staging qualification is permitted only on the staging VM"

existing_qualification="${K_COMMS_RECEIPT_DIR}/staging-qualification.json"
if [[ -f "$existing_qualification" ]] &&
  [[ "$(current_app_image)" == "$image" ]] &&
  [[ "$(current_app_revision)" == "$revision" ]] &&
  [[ "$(jq -r '.image' "$existing_qualification")" == "$image" ]] &&
  [[ "$(jq -r '.revision' "$existing_qualification")" == "$revision" ]]; then
  "${SCRIPT_DIR}/verify.sh" --environment staging
  log "the exact release already has a retained staging qualification receipt"
  readlink -f "$existing_qualification"
  exit 0
fi

candidate_receipt="$(readlink -f "${K_COMMS_RECEIPT_DIR}/current.json")"
require_file "$candidate_receipt"
[[ "$(jq -r '.schema' "$candidate_receipt")" == k-comms-deployment-receipt-v1 ]] ||
  die "current staging receipt is not a deployment receipt"
[[ "$(jq -r '.environment' "$candidate_receipt")" == staging ]] ||
  die "current deployment receipt is not for staging"
[[ "$(jq -r '.image' "$candidate_receipt")" == "$image" ]] ||
  die "current staging receipt does not match the candidate image"
[[ "$(jq -r '.revision' "$candidate_receipt")" == "$revision" ]] ||
  die "current staging receipt does not match the candidate revision"
previous_image="$(jq -r '.previous.image' "$candidate_receipt")"
previous_revision="$(jq -r '.previous.revision' "$candidate_receipt")"
[[ "$previous_image" != "$image" ]] ||
  die "a distinct previous release is required for rollback rehearsal"
initial_backup="$(jq -r '.backup_path' "$candidate_receipt")"
[[ -n "$initial_backup" && "$initial_backup" != null ]] ||
  die "candidate deployment receipt has no pre-deployment backup"

rollback_before="$(
  find "$K_COMMS_RECEIPT_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*-rollback-*.json' \
    -print |
    sort |
    tail -n 1
)"
"${SCRIPT_DIR}/rollback.sh" --receipt "$candidate_receipt"
"${SCRIPT_DIR}/verify.sh" --environment staging
rollback_receipt="$(
  find "$K_COMMS_RECEIPT_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*-rollback-*.json' \
    -print |
    sort |
    tail -n 1
)"
[[ -n "$rollback_receipt" && "$rollback_receipt" != "$rollback_before" ]] ||
  die "rollback rehearsal did not create a new receipt"
[[ "$(jq -r '.schema' "$rollback_receipt")" == k-comms-rollback-receipt-v1 ]] ||
  die "rollback rehearsal receipt has an unsupported schema"
[[ "$(jq -r '.from_image' "$rollback_receipt")" == "$image" ]] ||
  die "rollback receipt does not start from the candidate image"
[[ "$(jq -r '.to_image' "$rollback_receipt")" == "$previous_image" ]] ||
  die "rollback receipt does not end at the preceding image"
[[ "$(jq -r '.to_revision' "$rollback_receipt")" == "$previous_revision" ]] ||
  die "rollback receipt does not end at the preceding revision"

log "reactivating the exact candidate after rollback rehearsal"
"${SCRIPT_DIR}/deploy.sh" \
  --environment staging \
  --image "$image" \
  --revision "$revision" \
  --bootstrap
"${SCRIPT_DIR}/verify.sh" --environment staging
final_deployment_receipt="$(readlink -f "${K_COMMS_RECEIPT_DIR}/current.json")"
[[ "$(jq -r '.image' "$final_deployment_receipt")" == "$image" ]] ||
  die "reactivated staging image does not match the candidate"
[[ "$(jq -r '.revision' "$final_deployment_receipt")" == "$revision" ]] ||
  die "reactivated staging revision does not match the candidate"

restore_receipt="$(
  "${SCRIPT_DIR}/restore-rehearsal.sh" --backup "$initial_backup"
)"
require_file "$restore_receipt"
"${SCRIPT_DIR}/verify.sh" --environment staging

qualification_receipt="$(
  printf '%s/%s-%s-staging-qualification.json' \
    "$K_COMMS_RECEIPT_DIR" \
    "$(date -u +%Y%m%dT%H%M%SZ)" \
    "$revision"
)"
jq -n \
  --arg schema k-comms-staging-qualification-receipt-v1 \
  --arg qualified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg image "$image" \
  --arg revision "$revision" \
  --arg candidate_deployment_receipt "$candidate_receipt" \
  --arg final_deployment_receipt "$final_deployment_receipt" \
  --arg initial_backup "$initial_backup" \
  --arg rollback_receipt "$rollback_receipt" \
  --arg restore_rehearsal_receipt "$restore_receipt" \
  '{
    schema: $schema,
    environment: "staging",
    qualified_at: $qualified_at,
    image: $image,
    revision: $revision,
    candidate_deployment_receipt: $candidate_deployment_receipt,
    final_deployment_receipt: $final_deployment_receipt,
    initial_backup: $initial_backup,
    rollback_receipt: $rollback_receipt,
    restore_rehearsal_receipt: $restore_rehearsal_receipt
  }' >"$qualification_receipt"
chmod 0600 "$qualification_receipt"
ln -sfn "$(basename "$qualification_receipt")" \
  "${K_COMMS_RECEIPT_DIR}/staging-qualification.json"

log "staging deployment, rollback, reactivation, and isolated restore passed"
printf '%s\n' "$qualification_receipt"
