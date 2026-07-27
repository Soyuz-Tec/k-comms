#!/usr/bin/env bash
set -Eeuo pipefail

K_COMMS_CONFIG_DIR=/etc/k-comms
K_COMMS_RUNTIME_ENV="${K_COMMS_CONFIG_DIR}/runtime.env"
K_COMMS_RELEASE_ENV="${K_COMMS_CONFIG_DIR}/release.env"
K_COMMS_ENVIRONMENT_FILE="${K_COMMS_CONFIG_DIR}/environment"
K_COMMS_QUADLET_DIR=/etc/containers/systemd
K_COMMS_INSTALL_DIR=/opt/k-comms
K_COMMS_TEMPLATE_DIR="${K_COMMS_INSTALL_DIR}/templates"
K_COMMS_RECEIPT_DIR=/var/lib/k-comms/receipts
K_COMMS_BACKUP_ROOT=/var/backups/k-comms
K_COMMS_LOCK_FILE=/run/lock/k-comms-deploy.lock
K_COMMS_SOURCE=https://github.com/Soyuz-Tec/k-comms
K_COMMS_CAPABILITIES=guest_identity_v1,guest_admission_expiry_worker_v1,instant_room_lifecycle_v1,instant_room_presence_lease_v1,instant_room_expiry_worker_v1,conversation_only_human_v1
K_COMMS_MINIO_MC_IMAGE=docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:eb4ea9884b77704230e2423e9004d2fa738dc272876b9cc41a297d29443b8780

log() {
  printf '[k-comms] %s\n' "$*" >&2
}

die() {
  printf '[k-comms] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "this operation must run as root"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file is missing: $1"
}

validate_environment() {
  [[ "$1" == staging || "$1" == production ]] ||
    die "environment must be staging or production"
}

validate_image_ref() {
  [[ "$1" =~ ^ghcr\.io/soyuz-tec/k-comms@sha256:[0-9a-f]{64}$ ]] ||
    die "image must be the immutable ghcr.io/soyuz-tec/k-comms@sha256:<digest> reference"
}

validate_revision() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] ||
    die "revision must be a 40-character lowercase Git commit"
}

validate_ipv4() {
  local address=$1
  local octet
  local -a octets

  IFS=. read -r -a octets <<<"$address"
  [[ ${#octets[@]} -eq 4 ]] || die "invalid IPv4 address: $address"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] &&
      ((10#$octet <= 255)) || die "invalid IPv4 address: $address"
  done
}

read_env_value() {
  local file=$1
  local name=$2
  local line

  require_file "$file"
  line="$(grep -E "^${name}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || die "${name} is missing from ${file}"
  printf '%s' "${line#*=}"
}

read_optional_env_value() {
  local file=$1
  local name=$2
  local line

  [[ -f "$file" ]] || return 0
  line="$(grep -E "^${name}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] && printf '%s' "${line#*=}"
}

assert_secure_runtime_env() {
  require_file "$K_COMMS_RUNTIME_ENV"
  [[ "$(stat -c '%a' "$K_COMMS_RUNTIME_ENV")" == 600 ]] ||
    die "${K_COMMS_RUNTIME_ENV} must have mode 0600"
  ! grep -q 'CHANGE_ME' "$K_COMMS_RUNTIME_ENV" ||
    die "${K_COMMS_RUNTIME_ENV} still contains CHANGE_ME placeholders"
}

render_template() {
  local source=$1
  local destination=$2
  shift 2
  local content
  local key
  local value

  require_file "$source"
  content="$(<"$source")"
  while (($#)); do
    key=$1
    value=$2
    shift 2
    [[ "$value" != *"@@"* && "$value" != *$'\n'* ]] ||
      die "unsafe template value for ${key}"
    content="${content//@@${key}@@/${value}}"
  done
  [[ "$content" != *"@@"* ]] || die "unresolved placeholder in ${source}"
  install -m 0644 /dev/null "$destination"
  printf '%s\n' "$content" >"$destination"
}

acquire_deploy_lock() {
  mkdir -p "$(dirname "$K_COMMS_LOCK_FILE")"
  exec 9>"$K_COMMS_LOCK_FILE"
  flock -n 9 || die "another K-Comms deployment or recovery operation is running"
}

container_exists() {
  podman container exists "$1"
}

unit_active() {
  systemctl is-active --quiet "$1"
}

wait_for_url() {
  local url=$1
  local attempts=${2:-60}
  local delay=${3:-2}
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl --fail --silent --show-error --max-time 5 "$url" >/dev/null; then
      return 0
    fi
    sleep "$delay"
  done
  die "health endpoint did not become ready: ${url}"
}

write_release_env() {
  local image=$1
  local revision=$2
  local destination=$3

  install -m 0600 /dev/null "$destination"
  {
    printf 'K_COMMS_RELEASE_IMAGE=%s\n' "$image"
    printf 'K_COMMS_RELEASE_REVISION=%s\n' "$revision"
  } >"$destination"
}

configured_bind_address() {
  read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_BIND_ADDRESS
}

configured_environment() {
  read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_ENVIRONMENT
}

expected_minio_volume_path() {
  printf '/var/lib/containers/storage/volumes/k-comms-minio-data/_data'
}

assert_minio_volume_path() {
  local actual
  local expected

  expected="$(expected_minio_volume_path)"
  actual="$(podman volume inspect k-comms-minio-data --format '{{.Mountpoint}}')"
  [[ "$actual" == "$expected" ]] ||
    die "refusing object-storage operation: expected ${expected}, found ${actual}"
  [[ -d "$actual" ]] || die "MinIO volume path does not exist: ${actual}"
  printf '%s' "$actual"
}

current_app_image() {
  if container_exists k-comms-app; then
    podman inspect k-comms-app --format '{{.ImageName}}'
  fi
}

current_app_revision() {
  if container_exists k-comms-app; then
    podman inspect k-comms-app --format '{{index .Config.Labels "io.k-comms.revision"}}'
  fi
}

current_app_capabilities() {
  if container_exists k-comms-app; then
    podman inspect k-comms-app \
      --format '{{index .Config.Labels "io.k-comms.rollback-capabilities"}}'
  fi
}
