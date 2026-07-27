#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

environment=
bind_address=
output=/etc/k-comms/runtime.env

while (($#)); do
  case "$1" in
    --environment) environment=${2:-}; shift 2 ;;
    --bind-address) bind_address=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
require_command openssl
validate_environment "$environment"
validate_ipv4 "$bind_address"
[[ "$environment" == staging ]] ||
  die "automatic secret generation is staging-only; production secrets must be imported through the approved migration path"
[[ ! -e "$output" ]] || die "refusing to overwrite existing runtime configuration: $output"

hex_secret() {
  openssl rand -hex "$1"
}

base64_secret() {
  openssl rand -base64 "$1" | tr -d '\n'
}

base64url_secret() {
  openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\n'
}

postgres_password="$(hex_secret 32)"
secret_key_base="$(base64_secret 64)"
password_recovery_key="$(base64_secret 32)"
webhook_encryption_key="$(base64_secret 32)"
push_encryption_key="$(base64_secret 32)"
metrics_token="$(hex_secret 32)"
livekit_key="$(hex_secret 16)"
livekit_secret="$(hex_secret 32)"
minio_password="$(hex_secret 32)"
bootstrap_password="$(base64url_secret 24)"
app_origin="http://${bind_address}:4188"
livekit_origin="ws://${bind_address}:7980"
object_origin="http://${bind_address}:5900"

install -d -m 0750 "$(dirname "$output")"
install -m 0600 /dev/null "$output"
{
  printf 'POSTGRES_USER=kcomms\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$postgres_password"
  printf 'POSTGRES_DB=k_comms_release\n'
  printf 'DATABASE_URL=ecto://kcomms:%s@postgres/k_comms_release\n' "$postgres_password"
  printf 'POOL_SIZE=10\n'
  printf 'SECRET_KEY_BASE=%s\n' "$secret_key_base"
  printf 'PASSWORD_RECOVERY_SIGNING_KEY=%s\n' "$password_recovery_key"
  printf 'WEBHOOK_SECRET_ENCRYPTION_KEY=%s\n' "$webhook_encryption_key"
  printf 'WEBHOOK_SECRET_ENCRYPTION_KEY_ID=primary\n'
  printf 'PUSH_SUBSCRIPTION_ENCRYPTION_KEY=%s\n' "$push_encryption_key"
  printf 'PUSH_SUBSCRIPTION_ENCRYPTION_KEY_ID=primary\n'
  printf 'METRICS_BEARER_TOKEN=%s\n' "$metrics_token"
  printf 'PUBLIC_APP_URL=%s\n' "$app_origin"
  printf 'PHX_HOST=%s\n' "$bind_address"
  printf 'PORT=4000\n'
  printf 'K_COMMS_RELEASE_HOST=%s\n' "$bind_address"
  printf 'K_COMMS_LOCAL_RELEASE_HOST=%s\n' "$bind_address"
  printf 'K_COMMS_RELEASE_EXPOSURE_MODE=\n'
  printf 'K_COMMS_TRUSTED_EDGE_CONFIRMATION=\n'
  printf 'CORS_ORIGINS=%s\n' "$app_origin"
  printf "CSP_CONNECT_SOURCES='self' %s %s %s %s\n" \
    "$app_origin" \
    "ws://${bind_address}:4188" \
    "$livekit_origin" \
    "$object_origin"
  printf 'HSTS_ENABLED=false\n'
  printf 'TRUSTED_PROXY_CIDRS=\n'
  printf 'ALLOW_BOOTSTRAP=false\n'
  printf 'INSTANT_ROOMS_ENABLED=true\n'
  printf 'INSTANT_ROOM_TENANT_SLUG=k-comms-staging\n'
  printf 'INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS=3600\n'
  printf 'INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS=86400\n'
  printf 'INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS=30\n'
  printf 'INSTANT_ROOM_PRESENCE_LEASE_SECONDS=90\n'
  printf 'INSTANT_ROOM_RECONNECT_GRACE_SECONDS=90\n'
  printf 'INSTANT_ROOM_MAX_PARTICIPANTS=25\n'
  printf 'ACCESS_TOKEN_TTL_SECONDS=3600\n'
  printf 'SESSION_TTL_SECONDS=2592000\n'
  printf 'SESSION_ABSOLUTE_TTL_SECONDS=2592000\n'
  printf 'PASSWORD_RECOVERY_TTL_SECONDS=1800\n'
  printf 'PASSWORD_RECOVERY_RETENTION_SECONDS=2592000\n'
  printf 'PASSWORD_RECOVERY_MIN_RESPONSE_MS=500\n'
  printf 'PASSWORD_RECOVERY_JITTER_MS=50\n'
  printf 'ALLOW_DEVELOPMENT_ADAPTERS=true\n'
  printf 'NOTIFICATION_PROVIDER_MODE=log\n'
  printf 'NOTIFICATION_PROVIDER_NAME=proxmox-release-log\n'
  printf 'ATTACHMENT_SCANNER_MODE=allow_all\n'
  printf 'ATTACHMENT_SCANNER_PROVIDER_NAME=proxmox-release-allow-all\n'
  printf 'WEBHOOK_PROVIDER_MODE=log\n'
  printf 'WEBHOOK_ALLOWED_HOSTS=webhook.local\n'
  printf 'WEB_PUSH_VAPID_PUBLIC_KEY=BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo\n'
  printf 'METRICS_ALLOW_UNAUTHENTICATED=false\n'
  printf 'LIVEKIT_SERVER_URL=%s\n' "$livekit_origin"
  printf 'LIVEKIT_API_URL=http://livekit:7880\n'
  printf 'LIVEKIT_API_KEY=%s\n' "$livekit_key"
  printf 'LIVEKIT_API_SECRET=%s\n' "$livekit_secret"
  printf 'LIVEKIT_KEYS=%s: %s\n' "$livekit_key" "$livekit_secret"
  printf 'K_COMMS_LIVEKIT_TOPOLOGY=local_sidecar\n'
  printf 'K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=\n'
  printf 'AUDIO_PROVIDER_MODE=livekit\n'
  printf 'AUDIO_TOKEN_TTL_SECONDS=300\n'
  printf 'AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS=660\n'
  printf 'MINIO_ROOT_USER=kcomms\n'
  printf 'MINIO_ROOT_PASSWORD=%s\n' "$minio_password"
  printf 'MINIO_API_CORS_ALLOW_ORIGIN=%s\n' "$app_origin"
  printf 'S3_PUBLIC_ENDPOINT=%s\n' "$object_origin"
  printf 'S3_INTERNAL_ENDPOINT=http://minio:9000\n'
  printf 'S3_ACCESS_KEY_ID=kcomms\n'
  printf 'S3_SECRET_ACCESS_KEY=%s\n' "$minio_password"
  printf 'S3_BUCKET=k-comms-release\n'
  printf 'S3_REGION=us-east-1\n'
  printf 'BOOTSTRAP_TENANT_NAME=K-Comms Staging\n'
  printf 'BOOTSTRAP_TENANT_SLUG=k-comms-staging\n'
  printf 'BOOTSTRAP_OWNER_DISPLAY_NAME=Staging Owner\n'
  printf 'BOOTSTRAP_OWNER_EMAIL=staging-owner@k-comms.invalid\n'
  printf 'BOOTSTRAP_OWNER_PASSWORD=%s\n' "$bootstrap_password"
} >"$output"

chmod 0600 "$output"
log "created protected staging configuration at ${output}; no secret values were printed"
