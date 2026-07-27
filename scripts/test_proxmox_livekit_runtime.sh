#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deploy/proxmox/bin/common.sh
source "${REPO_ROOT}/deploy/proxmox/bin/common.sh"

for command in chmod cmp grep install jq mktemp stat; do
  require_command "$command"
done

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/k-comms-livekit-test.XXXXXX")"
cleanup() {
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT

K_COMMS_RUNTIME_ENV="${fixture_root}/runtime.env"
credential_file="${fixture_root}/credential.json"
candidate_file="${fixture_root}/candidate.env"
rotated_file="${fixture_root}/rotated.env"

install -m 0600 /dev/null "$K_COMMS_RUNTIME_ENV"
{
  printf 'LIVEKIT_SERVER_URL=ws://192.168.1.23:7980\n'
  printf 'LIVEKIT_API_URL=http://livekit:7880\n'
  printf 'LIVEKIT_API_KEY=local-test-key\n'
  printf 'LIVEKIT_API_SECRET=local-test-secret-material-00000000\n'
  printf 'LIVEKIT_KEYS=local-test-key: local-test-secret-material-00000000\n'
  printf 'K_COMMS_LIVEKIT_TOPOLOGY=local_sidecar\n'
  printf 'K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=\n'
  printf "CSP_CONNECT_SOURCES='self' http://192.168.1.23:4188 "
  printf 'ws://192.168.1.23:4188 ws://192.168.1.23:7980 '
  printf 'http://192.168.1.23:5900\n'
} >"$K_COMMS_RUNTIME_ENV"

jq -n \
  --arg url wss://project-test.livekit.cloud \
  --arg apiKey APItestfixture01 \
  --arg apiSecret testfixturesecretmaterial00000000000000000000 \
  '{url: $url, apiKey: $apiKey, apiSecret: $apiSecret}' >"$credential_file"
chmod 0600 "$credential_file"

write_managed_livekit_runtime_env "$credential_file" "$candidate_file"

grep -qx 'K_COMMS_LIVEKIT_TOPOLOGY=managed_cloud' "$candidate_file"
grep -qx \
  'K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=livekit-cloud-v1' \
  "$candidate_file"
grep -qx \
  'LIVEKIT_API_URL=https://project-test.livekit.cloud' \
  "$candidate_file"
grep -qx \
  "CSP_CONNECT_SOURCES='self' http://192.168.1.23:4188 ws://192.168.1.23:4188 wss://project-test.livekit.cloud http://192.168.1.23:5900" \
  "$candidate_file"
[[ "$(stat -c '%a' "$candidate_file")" == 600 ]]

K_COMMS_RUNTIME_ENV="$candidate_file"
write_managed_livekit_runtime_env "$credential_file" "$rotated_file"
cmp --silent "$candidate_file" "$rotated_file"

printf 'Managed LiveKit runtime transaction test passed.\n'
