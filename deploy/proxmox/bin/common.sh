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
K_COMMS_LOCAL_LIVEKIT_TOPOLOGY=local_sidecar
K_COMMS_MANAGED_LIVEKIT_TOPOLOGY=managed_cloud
K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=livekit-cloud-v1

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

validate_volume_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]{0,127}$ ]] ||
    die "invalid rootful Podman volume name: $1"
}

validate_storage_mode() {
  [[ "$1" == fresh || "$1" == adopted ]] ||
    die "storage mode must be fresh or adopted"
}

validate_adopted_local_image_ref() {
  [[ "$1" =~ ^localhost/k-comms:proxmox-[0-9a-f]{7,40}$ ]] ||
    die "adopted local image must be localhost/k-comms:proxmox-<revision>"
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

validate_ipv4_24_subnet() {
  local cidr=$1
  local address=${cidr%/24}

  [[ "$cidr" == */24 ]] || die "Podman network subnet must use a /24 prefix"
  validate_ipv4 "$address"
  [[ "${address##*.}" == 0 ]] ||
    die "Podman /24 subnet must use its network address: ${cidr}"
}

validate_livekit_topology() {
  [[ "$1" == "$K_COMMS_LOCAL_LIVEKIT_TOPOLOGY" ||
    "$1" == "$K_COMMS_MANAGED_LIVEKIT_TOPOLOGY" ]] ||
    die "LiveKit topology must be local_sidecar or managed_cloud"
}

validate_managed_livekit_url() {
  [[ "$1" =~ ^wss://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.livekit\.cloud$ ]] ||
    die "managed LiveKit URL must be an exact wss://<project>.livekit.cloud origin"
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
  return 0
}

assert_secure_runtime_env() {
  require_file "$K_COMMS_RUNTIME_ENV"
  [[ "$(stat -c '%a' "$K_COMMS_RUNTIME_ENV")" == 600 ]] ||
    die "${K_COMMS_RUNTIME_ENV} must have mode 0600"
  ! grep -q 'CHANGE_ME' "$K_COMMS_RUNTIME_ENV" ||
    die "${K_COMMS_RUNTIME_ENV} still contains CHANGE_ME placeholders"
}

configured_livekit_topology() {
  local value

  value="$(read_optional_env_value "$K_COMMS_RUNTIME_ENV" K_COMMS_LIVEKIT_TOPOLOGY)"
  printf '%s' "${value:-$K_COMMS_LOCAL_LIVEKIT_TOPOLOGY}"
}

assert_managed_livekit_runtime() {
  local topology
  local confirmation
  local server_url
  local api_url

  topology="$(configured_livekit_topology)"
  validate_livekit_topology "$topology"
  [[ "$topology" == "$K_COMMS_MANAGED_LIVEKIT_TOPOLOGY" ]] || return 0

  confirmation="$(
    read_env_value "$K_COMMS_RUNTIME_ENV" K_COMMS_MANAGED_LIVEKIT_CONFIRMATION
  )"
  [[ "$confirmation" == "$K_COMMS_MANAGED_LIVEKIT_CONFIRMATION" ]] ||
    die "managed LiveKit confirmation is missing or invalid"

  server_url="$(read_env_value "$K_COMMS_RUNTIME_ENV" LIVEKIT_SERVER_URL)"
  api_url="$(read_env_value "$K_COMMS_RUNTIME_ENV" LIVEKIT_API_URL)"
  validate_managed_livekit_url "$server_url"
  [[ "$api_url" == "https://${server_url#wss://}" ]] ||
    die "managed LiveKit API URL must match the signaling host"
}

write_managed_livekit_runtime_env() {
  local credential_file=$1
  local destination=$2
  local server_url
  local api_url
  local api_key
  local api_secret
  local current_server_url
  local current_csp
  local candidate_csp
  local csp_prefix
  local csp_suffix
  local line
  local name
  local seen_topology=false
  local seen_confirmation=false

  require_file "$credential_file"
  [[ ! -L "$credential_file" ]] ||
    die "managed LiveKit credential must not be a symbolic link"
  [[ "$(stat -c '%a' "$credential_file")" == 600 ]] ||
    die "managed LiveKit credential must have mode 0600"

  server_url="$(
    jq -er '
      if ((keys | sort) == ["apiKey", "apiSecret", "url"]) and
         (.url | type) == "string"
      then .url else empty end
    ' "$credential_file"
  )" || die "managed LiveKit credential has an invalid URL field"
  api_key="$(
    jq -er '
      if ((keys | sort) == ["apiKey", "apiSecret", "url"]) and
         (.apiKey | type) == "string"
      then .apiKey else empty end
    ' "$credential_file"
  )" || die "managed LiveKit credential has an invalid API key field"
  api_secret="$(
    jq -er '
      if ((keys | sort) == ["apiKey", "apiSecret", "url"]) and
         (.apiSecret | type) == "string"
      then .apiSecret else empty end
    ' "$credential_file"
  )" || die "managed LiveKit credential has an invalid API secret field"

  validate_managed_livekit_url "$server_url"
  [[ "$api_key" =~ ^API[A-Za-z0-9_-]{8,}$ ]] ||
    die "managed LiveKit API key has an invalid shape"
  [[ "$api_secret" =~ ^[A-Za-z0-9_-]{32,}$ ]] ||
    die "managed LiveKit API secret has an invalid shape"

  api_url="https://${server_url#wss://}"
  current_server_url="$(read_env_value "$K_COMMS_RUNTIME_ENV" LIVEKIT_SERVER_URL)"
  current_csp="$(read_env_value "$K_COMMS_RUNTIME_ENV" CSP_CONNECT_SOURCES)"
  [[ "$current_csp" == *"$current_server_url"* ]] ||
    die "CSP_CONNECT_SOURCES does not contain the current LiveKit origin"
  csp_prefix="${current_csp%%"$current_server_url"*}"
  csp_suffix="${current_csp#*"$current_server_url"}"
  [[ "$csp_suffix" != *"$current_server_url"* ]] ||
    die "CSP_CONNECT_SOURCES contains the current LiveKit origin more than once"
  candidate_csp="${csp_prefix}${server_url}${csp_suffix}"

  install -m 0600 /dev/null "$destination"
  while IFS= read -r line || [[ -n "$line" ]]; do
    name=${line%%=*}
    case "$name" in
      LIVEKIT_SERVER_URL) printf 'LIVEKIT_SERVER_URL=%s\n' "$server_url" ;;
      LIVEKIT_API_URL) printf 'LIVEKIT_API_URL=%s\n' "$api_url" ;;
      LIVEKIT_API_KEY) printf 'LIVEKIT_API_KEY=%s\n' "$api_key" ;;
      LIVEKIT_API_SECRET) printf 'LIVEKIT_API_SECRET=%s\n' "$api_secret" ;;
      CSP_CONNECT_SOURCES) printf 'CSP_CONNECT_SOURCES=%s\n' "$candidate_csp" ;;
      K_COMMS_LIVEKIT_TOPOLOGY)
        printf 'K_COMMS_LIVEKIT_TOPOLOGY=%s\n' "$K_COMMS_MANAGED_LIVEKIT_TOPOLOGY"
        seen_topology=true
        ;;
      K_COMMS_MANAGED_LIVEKIT_CONFIRMATION)
        printf 'K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=%s\n' \
          "$K_COMMS_MANAGED_LIVEKIT_CONFIRMATION"
        seen_confirmation=true
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$K_COMMS_RUNTIME_ENV" >"$destination"

  if [[ "$seen_topology" == false ]]; then
    printf 'K_COMMS_LIVEKIT_TOPOLOGY=%s\n' \
      "$K_COMMS_MANAGED_LIVEKIT_TOPOLOGY" >>"$destination"
  fi
  if [[ "$seen_confirmation" == false ]]; then
    printf 'K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=%s\n' \
      "$K_COMMS_MANAGED_LIVEKIT_CONFIRMATION" >>"$destination"
  fi

  chmod 0600 "$destination"
  ! grep -q 'CHANGE_ME' "$destination" ||
    die "candidate runtime configuration contains placeholders"
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

configured_storage_mode() {
  read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_STORAGE_MODE
}

configured_postgres_volume() {
  read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_POSTGRES_VOLUME
}

configured_minio_volume() {
  read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_MINIO_VOLUME
}

configured_network_subnet() {
  read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_NETWORK_SUBNET
}

configured_network_gateway() {
  read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_NETWORK_GATEWAY
}

classify_image_ref() {
  local image=${1:-}

  if [[ "$image" =~ ^ghcr\.io/soyuz-tec/k-comms@sha256:[0-9a-f]{64}$ ]]; then
    printf 'immutable-ghcr'
  elif [[ "$image" =~ ^localhost/k-comms:proxmox-[0-9a-f]{7,40}$ ]]; then
    printf 'adopted-local'
  elif [[ -n "$image" ]]; then
    printf 'unknown'
  fi
}

expected_volume_path() {
  local volume=$1

  validate_volume_name "$volume"
  printf '/var/lib/containers/storage/volumes/%s/_data' "$volume"
}

assert_volume_path() {
  local volume=$1
  local actual
  local expected

  validate_volume_name "$volume"
  expected="$(expected_volume_path "$volume")"
  actual="$(podman volume inspect "$volume" --format '{{.Mountpoint}}')"
  [[ "$actual" == "$expected" ]] ||
    die "refusing storage operation: expected ${expected}, found ${actual}"
  [[ -d "$actual" ]] || die "volume path does not exist: ${actual}"
  printf '%s' "$actual"
}

assert_no_foreign_running_mount() {
  local volume=$1
  local expected_container=$2
  local container_id
  local container_name
  local mounts

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    container_name="$(podman inspect "$container_id" --format '{{.Name}}')"
    [[ "$container_name" == "$expected_container" ]] && continue
    mounts="$(podman inspect "$container_id" \
      --format '{{range .Mounts}}{{.Name}}:{{.Destination}};{{end}}')"
    [[ "$mounts" != *"${volume}:"* ]] ||
      die "volume ${volume} is still mounted by running container ${container_name}"
  done < <(podman ps --quiet)
}

assert_postgres_volume_path() {
  local volume
  local path

  volume="$(configured_postgres_volume)"
  validate_volume_name "$volume"
  path="$(assert_volume_path "$volume")"
  [[ -f "${path}/PG_VERSION" ]] ||
    die "PostgreSQL volume is missing PG_VERSION: ${volume}"
  printf '%s' "$path"
}

expected_minio_volume_path() {
  expected_volume_path "$(configured_minio_volume)"
}

assert_minio_volume_path() {
  local volume
  local actual
  local expected

  volume="$(configured_minio_volume)"
  validate_volume_name "$volume"
  expected="$(expected_minio_volume_path)"
  actual="$(podman volume inspect "$volume" --format '{{.Mountpoint}}')"
  [[ "$actual" == "$expected" ]] ||
    die "refusing object-storage operation: expected ${expected}, found ${actual}"
  [[ -d "$actual" ]] || die "MinIO volume path does not exist: ${actual}"
  [[ -f "${actual}/.minio.sys/format.json" ]] ||
    die "MinIO volume is missing its format marker: ${volume}"
  printf '%s' "$actual"
}

assert_adopted_storage_ready_for_activation() {
  local storage_mode
  local postgres_volume
  local minio_volume

  storage_mode="$(configured_storage_mode)"
  validate_storage_mode "$storage_mode"
  [[ "$storage_mode" == adopted ]] || return 0

  postgres_volume="$(configured_postgres_volume)"
  minio_volume="$(configured_minio_volume)"
  assert_postgres_volume_path >/dev/null
  assert_minio_volume_path >/dev/null
  assert_no_foreign_running_mount "$postgres_volume" k-comms-postgres
  assert_no_foreign_running_mount "$minio_volume" k-comms-minio
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
