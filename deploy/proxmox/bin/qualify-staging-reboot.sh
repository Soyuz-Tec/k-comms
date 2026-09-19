#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

action=
image=
revision=
request_id=
previous_boot_id=
while (($#)); do
  case "$1" in
    --action) action=${2:-}; shift 2 ;;
    --image) image=${2:-}; shift 2 ;;
    --revision) revision=${2:-}; shift 2 ;;
    --request-id) request_id=${2:-}; shift 2 ;;
    --previous-boot-id) previous_boot_id=${2:-}; shift 2 ;;
    *) die "unknown staging reboot argument" ;;
  esac
done

require_root
for command in jq systemctl systemd-run timeout; do require_command "$command"; done
[[ "$action" == request || "$action" == verify ]] || die "invalid staging reboot action"
validate_image_ref "$image"
validate_revision "$revision"
uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "$request_id" =~ $uuid_pattern ]] || die "invalid staging reboot request ID"
# Defense in depth beyond the protected workflow's staging-only step and fixed
# SSH destination: a production VM must never honor this operation.
[[ "$(configured_environment)" == staging && "$(configured_bind_address)" == 192.168.1.23 ]] ||
  die "reboot qualification is permitted only on the configured staging VM"
acquire_deploy_lock
[[ "$(current_app_image)" == "$image" && "$(current_app_revision)" == "$revision" ]] ||
  die "staging reboot candidate does not match the running release"
boot_id="$(cat /proc/sys/kernel/random/boot_id)"
[[ "$boot_id" =~ $uuid_pattern ]] || die "host boot identity is invalid"
pending="${K_COMMS_RECEIPT_DIR}/staging-reboot-request-${request_id}.json"

if [[ "$action" == request ]]; then
  [[ ! -e "$pending" ]] || die "staging reboot request already exists"
  qualification="${K_COMMS_RECEIPT_DIR}/staging-qualification.json"
  jq -e --arg image "$image" --arg revision "$revision" '
    (.qualified_at | fromdateiso8601) as $qualified |
    .schema == "k-comms-staging-qualification-receipt-v1" and
    .environment == "staging" and .image == $image and .revision == $revision and
    (now - 86400 <= $qualified) and ($qualified <= now + 300)
  ' "$qualification" >/dev/null || die "staging rollback/restore qualification is required before reboot"
  umask 077
  jq -n --arg request_id "$request_id" --arg image "$image" --arg revision "$revision" \
    --arg previous_boot_id "$boot_id" --arg requested_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: "k-comms-staging-reboot-request-v1", environment: "staging",
      request_id: $request_id, image: $image, revision: $revision,
      previous_boot_id: $previous_boot_id, requested_at: $requested_at}' >"$pending"
  chmod 0600 "$pending"
  # A delayed transient timer lets SSH acknowledge scheduling before disconnect.
  # No background shell, password prompt, or weakened host-key verification.
  systemd-run --quiet --unit="k-comms-staging-reboot-${request_id}" \
    --on-active=5s --timer-property=AccuracySec=1s /usr/bin/systemctl reboot
  printf '%s\n' "$boot_id"
  exit 0
fi

[[ "$previous_boot_id" =~ $uuid_pattern ]] || die "invalid previous boot identity"
[[ "$boot_id" != "$previous_boot_id" ]] || die "staging reboot has not completed"
[[ -f "$pending" && ! -L "$pending" && "$(stat -c '%a:%u' "$pending")" == 600:0 ]] ||
  die "staging reboot request is missing or insecure"
jq -e --arg request_id "$request_id" --arg image "$image" --arg revision "$revision" \
  --arg previous_boot_id "$previous_boot_id" '
    (.requested_at | fromdateiso8601) as $requested |
    .schema == "k-comms-staging-reboot-request-v1" and .environment == "staging" and
    .request_id == $request_id and .image == $image and .revision == $revision and
    .previous_boot_id == $previous_boot_id and
    (now - 1800 <= $requested) and ($requested <= now + 300)
  ' "$pending" >/dev/null || die "staging reboot request does not match this recovery"

timeout 120 "${SCRIPT_DIR}/verify.sh" --environment staging --require-pwa >/dev/null
assert_running_service_environments >/dev/null
for timer in k-comms-health.timer k-comms-backup.timer; do
  systemctl is-enabled --quiet "$timer"
  systemctl is-active --quiet "$timer"
done
receipt="${K_COMMS_RECEIPT_DIR}/staging-reboot-${request_id}.json"
umask 077
jq -n --arg request_id "$request_id" --arg image "$image" --arg revision "$revision" \
  --arg previous_boot_id "$previous_boot_id" --arg boot_id "$boot_id" \
  --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema: "k-comms-staging-reboot-receipt-v1", environment: "staging",
    request_id: $request_id, image: $image, revision: $revision,
    previous_boot_id: $previous_boot_id, boot_id: $boot_id, verified_at: $verified_at,
    readiness_verified: true, timers_verified: true, service_environments_verified: true}' >"$receipt"
chmod 0600 "$receipt"
ln -sfn "$(basename "$receipt")" "${K_COMMS_RECEIPT_DIR}/staging-reboot.json"
printf '%s\n' "$boot_id"
