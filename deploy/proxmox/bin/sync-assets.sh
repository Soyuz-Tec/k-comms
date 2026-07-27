#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
assert_secure_runtime_env
environment="$(configured_environment)"
bind_address="$(configured_bind_address)"
media_address="$(read_env_value "$K_COMMS_ENVIRONMENT_FILE" K_COMMS_MEDIA_ADDRESS)"
validate_environment "$environment"
validate_ipv4 "$bind_address"
validate_ipv4 "$media_address"

install -d -m 0755 \
  "$K_COMMS_QUADLET_DIR" \
  "${K_COMMS_INSTALL_DIR}/bin" \
  "$K_COMMS_TEMPLATE_DIR"
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
nft --check --file /etc/nftables.conf.k-comms
install -m 0644 /etc/nftables.conf.k-comms /etc/nftables.conf

install -m 0644 "${BUNDLE_DIR}"/systemd/k-comms-*.service /etc/systemd/system/
install -m 0644 "${BUNDLE_DIR}"/systemd/k-comms-*.timer /etc/systemd/system/
systemctl daemon-reload
if nft list table inet k_comms_filter >/dev/null 2>&1; then
  nft delete table inet k_comms_filter
fi
nft --file /etc/nftables.conf
log "synchronized reviewed deployment assets for ${environment}"
