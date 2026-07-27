#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

environment=
bind_address=
media_address=
postgres_volume=k-comms-postgres-data
minio_volume=k-comms-minio-data
storage_mode=fresh
network_subnet=10.89.0.0/24
network_gateway=10.89.0.1
prepare_only=false

while (($#)); do
  case "$1" in
    --environment) environment=${2:-}; shift 2 ;;
    --bind-address) bind_address=${2:-}; shift 2 ;;
    --media-address) media_address=${2:-}; shift 2 ;;
    --postgres-volume) postgres_volume=${2:-}; shift 2 ;;
    --minio-volume) minio_volume=${2:-}; shift 2 ;;
    --storage-mode) storage_mode=${2:-}; shift 2 ;;
    --network-subnet) network_subnet=${2:-}; shift 2 ;;
    --network-gateway) network_gateway=${2:-}; shift 2 ;;
    --prepare-only) prepare_only=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
validate_environment "$environment"
validate_ipv4 "$bind_address"
validate_ipv4 "$media_address"
validate_volume_name "$postgres_volume"
validate_volume_name "$minio_volume"
validate_storage_mode "$storage_mode"
validate_ipv4_24_subnet "$network_subnet"
validate_ipv4 "$network_gateway"
[[ "$network_gateway" == "${network_subnet%0/24}1" ]] ||
  die "Podman network gateway must be the first address in its /24 subnet"
[[ "$postgres_volume" != "$minio_volume" ]] ||
  die "PostgreSQL and MinIO must use different volumes"
if [[ "$environment" == production ]]; then
  [[ "$storage_mode" == adopted ]] ||
    die "this production VM must explicitly adopt its authoritative volumes"
  [[ "$network_subnet" == 10.90.0.0/24 && "$network_gateway" == 10.90.0.1 ]] ||
    die "this production VM must use its dedicated 10.90.0.0/24 Podman network"
fi
assert_secure_runtime_env

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  aardvark-dns ca-certificates curl jq nftables openssl podman postgresql-client \
  qemu-guest-agent tar

for command in curl flock jq nft podman sha256sum systemctl; do
  require_command "$command"
done

install -d -m 0755 \
  "$K_COMMS_QUADLET_DIR" \
  "$K_COMMS_INSTALL_DIR" \
  "${K_COMMS_INSTALL_DIR}/bin" \
  "$K_COMMS_TEMPLATE_DIR" \
  "$K_COMMS_RECEIPT_DIR"
install -d -m 0700 "$K_COMMS_BACKUP_ROOT"
install -d -m 0750 "$K_COMMS_CONFIG_DIR"

install -m 0755 "${BUNDLE_DIR}"/bin/*.sh "${K_COMMS_INSTALL_DIR}/bin/"
install -m 0644 "${BUNDLE_DIR}"/quadlet/*.in "$K_COMMS_TEMPLATE_DIR/"
install -m 0644 "${BUNDLE_DIR}/nftables.conf.in" "$K_COMMS_TEMPLATE_DIR/"
install -m 0644 "${BUNDLE_DIR}"/quadlet/k-comms-postgres.container "$K_COMMS_QUADLET_DIR/"

render_template \
  "${BUNDLE_DIR}/quadlet/k-comms.network.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms.network" \
  PODMAN_SUBNET "$network_subnet" \
  PODMAN_GATEWAY "$network_gateway"
render_template \
  "${BUNDLE_DIR}/quadlet/k-comms-postgres-data.volume.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms-postgres-data.volume" \
  POSTGRES_VOLUME "$postgres_volume"
render_template \
  "${BUNDLE_DIR}/quadlet/k-comms-minio-data.volume.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms-minio-data.volume" \
  MINIO_VOLUME "$minio_volume"
render_template \
  "${BUNDLE_DIR}/quadlet/k-comms-minio.container.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms-minio.container" \
  BIND_ADDRESS "$bind_address"
render_template \
  "${BUNDLE_DIR}/quadlet/k-comms-livekit.container.in" \
  "${K_COMMS_QUADLET_DIR}/k-comms-livekit.container" \
  BIND_ADDRESS "$bind_address" \
  MEDIA_ADDRESS "$media_address"

staging_rules=
if [[ "$environment" == staging ]]; then
  staging_rules="ip saddr 192.168.1.0/24 tcp dport { 4188, 5900, 7980 } accept"
fi

render_template \
  "${BUNDLE_DIR}/nftables.conf.in" \
  /etc/nftables.conf.k-comms \
  MEDIA_ADDRESS "$media_address" \
  PODMAN_SUBNET "$network_subnet" \
  PODMAN_GATEWAY "$network_gateway" \
  STAGING_LAN_RULES "$staging_rules"

nft --check --file /etc/nftables.conf.k-comms
if [[ "$prepare_only" == false ]]; then
  if [[ -f /etc/nftables.conf && ! -f /etc/nftables.conf.pre-k-comms ]]; then
    cp --preserve=mode,timestamps /etc/nftables.conf /etc/nftables.conf.pre-k-comms
  fi
  install -m 0644 /etc/nftables.conf.k-comms /etc/nftables.conf
fi

install -m 0644 "${BUNDLE_DIR}"/systemd/k-comms-*.service /etc/systemd/system/
install -m 0644 "${BUNDLE_DIR}"/systemd/k-comms-*.timer /etc/systemd/system/
install -m 0600 /dev/null "$K_COMMS_ENVIRONMENT_FILE"
{
  printf 'K_COMMS_ENVIRONMENT=%s\n' "$environment"
  printf 'K_COMMS_BIND_ADDRESS=%s\n' "$bind_address"
  printf 'K_COMMS_MEDIA_ADDRESS=%s\n' "$media_address"
  printf 'K_COMMS_STORAGE_MODE=%s\n' "$storage_mode"
  printf 'K_COMMS_POSTGRES_VOLUME=%s\n' "$postgres_volume"
  printf 'K_COMMS_MINIO_VOLUME=%s\n' "$minio_volume"
  printf 'K_COMMS_NETWORK_SUBNET=%s\n' "$network_subnet"
  printf 'K_COMMS_NETWORK_GATEWAY=%s\n' "$network_gateway"
} >"$K_COMMS_ENVIRONMENT_FILE"

systemctl daemon-reload
if [[ "$prepare_only" == true ]]; then
  log "prepared the ${environment} deployment contract without activating host controls"
  exit 0
fi
systemctl enable --now nftables.service
systemctl start qemu-guest-agent.service
systemctl enable k-comms-health.timer k-comms-backup.timer

log "installed the ${environment} Proxmox deployment contract"
log "application activation remains gated on deploy.sh with an attested digest"
