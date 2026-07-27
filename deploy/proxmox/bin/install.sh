#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

environment=
bind_address=
media_address=

while (($#)); do
  case "$1" in
    --environment) environment=${2:-}; shift 2 ;;
    --bind-address) bind_address=${2:-}; shift 2 ;;
    --media-address) media_address=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
validate_environment "$environment"
validate_ipv4 "$bind_address"
validate_ipv4 "$media_address"
assert_secure_runtime_env

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl jq nftables openssl podman postgresql-client tar

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
install -m 0644 "${BUNDLE_DIR}"/quadlet/*.network "$K_COMMS_QUADLET_DIR/"
install -m 0644 "${BUNDLE_DIR}"/quadlet/*.volume "$K_COMMS_QUADLET_DIR/"
install -m 0644 "${BUNDLE_DIR}"/quadlet/k-comms-postgres.container "$K_COMMS_QUADLET_DIR/"

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
  STAGING_LAN_RULES "$staging_rules"

if [[ -f /etc/nftables.conf && ! -f /etc/nftables.conf.pre-k-comms ]]; then
  cp --preserve=mode,timestamps /etc/nftables.conf /etc/nftables.conf.pre-k-comms
fi
install -m 0644 /etc/nftables.conf.k-comms /etc/nftables.conf
nft --check --file /etc/nftables.conf

install -m 0644 "${BUNDLE_DIR}"/systemd/k-comms-*.service /etc/systemd/system/
install -m 0644 "${BUNDLE_DIR}"/systemd/k-comms-*.timer /etc/systemd/system/
install -m 0600 /dev/null "$K_COMMS_ENVIRONMENT_FILE"
{
  printf 'K_COMMS_ENVIRONMENT=%s\n' "$environment"
  printf 'K_COMMS_BIND_ADDRESS=%s\n' "$bind_address"
  printf 'K_COMMS_MEDIA_ADDRESS=%s\n' "$media_address"
} >"$K_COMMS_ENVIRONMENT_FILE"

systemctl daemon-reload
systemctl enable --now nftables.service
systemctl enable k-comms-health.timer k-comms-backup.timer

log "installed the ${environment} Proxmox deployment contract"
log "application activation remains gated on deploy.sh with an attested digest"
