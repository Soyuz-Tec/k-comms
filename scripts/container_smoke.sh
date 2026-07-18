#!/usr/bin/env bash
set -euo pipefail

engine="${CONTAINER_ENGINE:-podman}"
image="${IMAGE:-localhost/k-comms:smoke}"
postgres_image="${POSTGRES_IMAGE:-docker.io/library/postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193}"
oci_source="${OCI_SOURCE:-https://github.com/Soyuz-Tec/k-comms}"
oci_revision="${OCI_REVISION:-unknown}"
oci_version="${OCI_VERSION:-dev}"
suffix="${RANDOM:-0}-$$"
network="k-comms-smoke-${suffix}"
postgres="k-comms-smoke-postgres-${suffix}"
app="k-comms-smoke-app-${suffix}"
secret_key_base="container-smoke-secret-key-base-at-least-sixty-four-bytes-000000000000000000"

cleanup() {
  "${engine}" rm --force "${app}" >/dev/null 2>&1 || true
  "${engine}" rm --force "${postgres}" >/dev/null 2>&1 || true
  "${engine}" network rm "${network}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_args=(
  build
  --target runtime
  --tag "${image}"
  --build-arg "OCI_SOURCE=${oci_source}"
  --build-arg "OCI_REVISION=${oci_revision}"
  --build-arg "OCI_VERSION=${oci_version}"
)
if [[ "$(basename "${engine}")" == "podman" || "$(basename "${engine}")" == "podman.exe" ]]; then
  # Podman's default OCI format discards Dockerfile HEALTHCHECK metadata.
  build_args+=(--format docker)
fi
"${engine}" "${build_args[@]}" .

assert_image_label() {
  local label="$1"
  local expected="$2"
  local actual
  actual="$("${engine}" image inspect --format "{{ index .Config.Labels \"${label}\" }}" "${image}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "image label ${label} was ${actual@Q}; expected ${expected@Q}" >&2
    exit 1
  fi
}

assert_image_label "org.opencontainers.image.source" "${oci_source}"
assert_image_label "org.opencontainers.image.revision" "${oci_revision}"
assert_image_label "org.opencontainers.image.version" "${oci_version}"

pull_postgres_image() {
  local attempt

  for attempt in 1 2 3; do
    if "${engine}" pull "${postgres_image}"; then
      return 0
    fi

    echo "PostgreSQL image pull attempt ${attempt} failed" >&2
    sleep "${attempt}"
  done

  echo "Unable to pull immutable PostgreSQL image ${postgres_image}" >&2
  return 1
}

launch_postgres() {
  local output

  if output="$("${engine}" run --detach --pull=never \
    --name "${postgres}" \
    --network "${network}" \
    --env POSTGRES_USER=postgres \
    --env POSTGRES_PASSWORD=postgres \
    --env POSTGRES_DB=k_comms_smoke \
    "${postgres_image}" 2>&1)"; then
    return 0
  fi

  echo "Unable to launch PostgreSQL smoke container:" >&2
  printf '%s\n' "${output}" >&2
  "${engine}" version >&2 || true
  "${engine}" info >&2 || true
  "${engine}" network inspect "${network}" >&2 || true
  return 1
}

"${engine}" network create "${network}" >/dev/null
pull_postgres_image
launch_postgres

for _ in $(seq 1 30); do
  if "${engine}" exec "${postgres}" pg_isready -U postgres -d k_comms_smoke >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! "${engine}" exec "${postgres}" pg_isready -U postgres -d k_comms_smoke >/dev/null; then
  "${engine}" logs "${postgres}" >&2 || true
  "${engine}" inspect --format '{{json .State}}' "${postgres}" >&2 || true
  echo "PostgreSQL smoke container did not become ready" >&2
  exit 1
fi

common_env=(
  --env "DATABASE_URL=ecto://postgres:postgres@${postgres}:5432/k_comms_smoke"
  --env "SECRET_KEY_BASE=${secret_key_base}"
  --env "PUBLIC_APP_URL=https://localhost"
  --env "PASSWORD_RECOVERY_SIGNING_KEY=container-smoke-password-recovery-signing-key-32-bytes"
  --env "PUSH_SUBSCRIPTION_ENCRYPTION_KEY=push-subscription-test-key-32byt"
  --env "WEB_PUSH_VAPID_PUBLIC_KEY=BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
  --env "PHX_HOST=localhost"
  --env "PORT=4000"
  --env "K_COMMS_ROLE=all"
  --env "ALLOW_BOOTSTRAP=true"
  --env "HSTS_ENABLED=false"
  --env "S3_PUBLIC_ENDPOINT=http://minio.invalid:9000"
  --env "S3_INTERNAL_SCHEME=http"
  --env "S3_INTERNAL_HOST=minio.invalid"
  --env "S3_INTERNAL_PORT=9000"
  --env "S3_INTERNAL_ENDPOINT=http://minio.invalid:9000"
  --env "S3_BUCKET=k-comms-smoke"
  --env "S3_REGION=us-east-1"
  --env "S3_ACCESS_KEY_ID=smoke"
  --env "S3_SECRET_ACCESS_KEY=smoke-only-secret"
)

application_env=(
  --env "K_COMMS_RUNTIME_PURPOSE=application"
  --env "AUDIO_PROVIDER_MODE=livekit"
  --env "LIVEKIT_SERVER_URL=wss://media.container-smoke.test"
  --env "LIVEKIT_API_URL=https://media-api.container-smoke.test"
  --env "LIVEKIT_API_KEY=container-smoke-key"
  --env "LIVEKIT_API_SECRET=container-smoke-livekit-api-secret-at-least-32-bytes"
  --env "AUDIO_TOKEN_TTL_SECONDS=300"
  --env "AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS=660"
  --env "CSP_CONNECT_SOURCES='self' http://127.0.0.1:4000 ws://127.0.0.1:4000 wss://media.container-smoke.test"
)

"${engine}" run --rm --network "${network}" \
  --env "K_COMMS_RUNTIME_PURPOSE=one_shot" "${common_env[@]}" \
  "${image}" eval 'CommsCore.Release.migrate()'

"${engine}" run --detach --name "${app}" --network "${network}" \
  "${common_env[@]}" "${application_env[@]}" "${image}" >/dev/null

healthy=false
for _ in $(seq 1 45); do
  state="$("${engine}" inspect --format '{{.State.Status}}' "${app}")"
  if [[ "${state}" == "exited" || "${state}" == "dead" ]]; then
    "${engine}" logs "${app}"
    exit 1
  fi
  health="$("${engine}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${app}")"
  if [[ "${health}" == "healthy" ]]; then
    healthy=true
    break
  fi
  sleep 2
done

if [[ "${healthy}" != "true" ]]; then
  "${engine}" logs "${app}"
  echo "container did not become healthy" >&2
  exit 1
fi

configured_user="$("${engine}" inspect --format '{{.Config.User}}' "${app}")"
if [[ -z "${configured_user}" || "${configured_user}" == "0" || "${configured_user}" == "root" ]]; then
  echo "runtime image must declare a non-root user" >&2
  exit 1
fi

"${engine}" exec "${app}" curl --fail --silent --show-error \
  http://127.0.0.1:4000/health/ready >/dev/null
"${engine}" exec "${app}" curl --fail --silent --show-error \
  http://127.0.0.1:4000/app/index.html >/dev/null
"${engine}" exec "${app}" sh -lc '
  curl --fail --silent --show-error --dump-header /tmp/k-comms-sw.headers \
    --output /tmp/k-comms-sw.js http://127.0.0.1:4000/app/k-comms-sw.js
  grep -Eiq "^content-type: (text|application)/javascript" /tmp/k-comms-sw.headers
  grep -Fq "safeActionUrl" /tmp/k-comms-sw.js
  ! grep -Eiq "<!doctype html|<html" /tmp/k-comms-sw.js
'

bootstrap_payload='{"tenant_name":"Container Smoke","tenant_slug":"container-smoke","display_name":"Smoke Owner","email":"owner@container-smoke.test","password":"correct-horse-battery-smoke"}'
bootstrap_response="$("${engine}" exec "${app}" curl --fail-with-body --silent --show-error \
  --request POST \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data "${bootstrap_payload}" \
  http://127.0.0.1:4000/api/v1/bootstrap)"

access_token="$(printf '%s' "${bootstrap_response}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
conversation_id="$(printf '%s' "${bootstrap_response}" | sed -n 's/.*"conversation":{[^}]*"id":"\([^"]*\)".*/\1/p')"
if [[ -z "${access_token}" || -z "${conversation_id}" ]]; then
  echo "bootstrap response did not include an access token and conversation id" >&2
  echo "${bootstrap_response}" >&2
  exit 1
fi

idempotency_key="container-smoke-message-0001"
send_message() {
  "${engine}" exec "${app}" curl --fail-with-body --silent --show-error \
    --request POST \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${access_token}" \
    --header "Idempotency-Key: ${idempotency_key}" \
    --data '{"body":"Hello from the container smoke gate"}' \
    "http://127.0.0.1:4000/api/v1/conversations/${conversation_id}/messages"
}

first_response="$(send_message)"
duplicate_response="$(send_message)"
message_id="$(printf '%s' "${first_response}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
duplicate_id="$(printf '%s' "${duplicate_response}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
if [[ -z "${message_id}" || "${message_id}" != "${duplicate_id}" ]]; then
  echo "idempotent send did not return one canonical message id" >&2
  exit 1
fi

replay_response="$("${engine}" exec "${app}" curl --fail-with-body --silent --show-error \
  --header 'Accept: application/json' \
  --header "Authorization: Bearer ${access_token}" \
  "http://127.0.0.1:4000/api/v1/conversations/${conversation_id}/messages?after_sequence=0&limit=50")"
if ! printf '%s' "${replay_response}" | grep --fixed-strings --quiet "\"id\":\"${message_id}\""; then
  echo "replay did not contain canonical message id ${message_id}" >&2
  echo "${replay_response}" >&2
  exit 1
fi

echo "Container runtime smoke passed as ${configured_user}; replayed message ${message_id}"
