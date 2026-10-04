#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_dir=${K_COMMS_CI_S3_STATE_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is required}/k-comms-s3-fixture}
cache_dir=${K_COMMS_CI_S3_CACHE_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is required}/k-comms-s3-build}
readonly minio_image='quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:a1a8bd4ac40ad7881a245bab97323e18f971e4d4cba2c2007ec1bedd21cbaba2'
readonly mc_image='quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:eb4ea9884b77704230e2423e9004d2fa738dc272876b9cc41a297d29443b8780'

owned_pid() {
  local pid=$1 started=$2 binary=$3 owner=${4:-} executable=
  [[ $pid =~ ^[0-9]+$ && $started =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
  [[ $(awk '{print $22}' "/proc/$pid/stat") == "$started" ]] || return 1
  # cmdline remains readable in sandboxes that deny /proc/PID/exe after a
  # background process is reparented. Compare only argv[0], never print args.
  IFS= read -r -d '' executable < "/proc/$pid/cmdline" || return 1
  [[ $executable == "$binary" ]] && return 0
  # env/nohup briefly own the freshly spawned PID before exec. The recorded
  # kernel start time and per-start owner let cleanup stop that transition
  # without touching a reused PID, even when startup fails immediately.
  [[ $owner =~ ^[a-f0-9]{32}$ ]] &&
    [[ $executable == env || $executable == /usr/bin/env ||
       $executable == nohup || $executable == /usr/bin/nohup ]]
}

stop_fixture() {
  local id owner= actual pid started binary
  [[ ! -f $state_dir/owner ]] || read -r owner < "$state_dir/owner"
  if [[ -f $state_dir/container && -f $state_dir/owner ]]; then
    read -r id < "$state_dir/container"
    read -r owner < "$state_dir/owner"
    if [[ $id =~ ^[a-f0-9]{64}$ && $owner =~ ^[a-f0-9]{32}$ ]]; then
      if ! actual=$(docker inspect --format '{{.Id}} {{ index .Config.Labels "org.k-comms.ci-s3-owner" }}' "$id" 2>/dev/null); then
        # A missing container is already stopped. A daemon/permission failure
        # must not silently discard the record of a possibly live container.
        actual=$(docker ps --all --no-trunc --filter "id=$id" --format '{{.ID}}') || return 1
        [[ -z $actual ]] || {
          echo 'Cannot verify ownership of the existing S3 container.' >&2; return 1;
        }
      fi
      if [[ $actual == "$id $owner" ]]; then
        docker rm --force "$id" >/dev/null
      elif [[ -n $actual ]]; then
        echo 'Refusing to remove an S3 container with different ownership.' >&2
        return 1
      fi
    else
      echo 'Invalid S3 container ownership state.' >&2
      return 1
    fi
    rm -f "$state_dir/container"
  fi
  if [[ -f $state_dir/process ]]; then
    read -r pid started binary < "$state_dir/process"
    if owned_pid "$pid" "$started" "$binary" "$owner"; then
      kill "$pid"
      for _ in {1..50}; do
        owned_pid "$pid" "$started" "$binary" "$owner" || break
        sleep 0.1
      done
      if owned_pid "$pid" "$started" "$binary" "$owner"; then
        kill -KILL "$pid"
        for _ in {1..50}; do
          owned_pid "$pid" "$started" "$binary" "$owner" || break
          sleep 0.1
        done
        if owned_pid "$pid" "$started" "$binary" "$owner"; then
          echo 'The owned native S3 fixture could not be stopped.' >&2
          return 1
        fi
      fi
    fi
    rm -f "$state_dir/process"
  fi
  rm -f "$state_dir/owner"
}

case ${1:-} in
  stop) stop_fixture; exit ;;
  start) ;;
  *) echo 'Usage: ci_s3_fixture.sh start|stop' >&2; exit 2 ;;
esac

: "${K_COMMS_TEST_S3_HOST:?}" "${K_COMMS_TEST_S3_PORT:?}" "${K_COMMS_TEST_S3_BUCKET:?}"
: "${K_COMMS_TEST_S3_ROOT_USER:?}" "${K_COMMS_TEST_S3_ROOT_PASSWORD:?}"
: "${K_COMMS_TEST_S3_ACCESS_KEY_ID:?}" "${K_COMMS_TEST_S3_SECRET_ACCESS_KEY:?}"
: "${K_COMMS_TEST_S3_KMS_SECRET_KEY:?}"
[[ $K_COMMS_TEST_S3_HOST == 127.0.0.1 ]] || {
  echo 'The CI S3 fixture must listen on loopback.' >&2; exit 1;
}
[[ $K_COMMS_TEST_S3_PORT =~ ^[0-9]{1,5}$ ]] &&
  ((10#$K_COMMS_TEST_S3_PORT >= 1024 && 10#$K_COMMS_TEST_S3_PORT <= 65535))
[[ $K_COMMS_TEST_S3_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]
[[ $K_COMMS_TEST_S3_ACCESS_KEY_ID != "$K_COMMS_TEST_S3_ROOT_USER" ]]
[[ $K_COMMS_TEST_S3_SECRET_ACCESS_KEY != "$K_COMMS_TEST_S3_ROOT_PASSWORD" ]]
mkdir -p "$state_dir" "$cache_dir"
state_dir=$(realpath "$state_dir")
cache_dir=$(realpath "$cache_dir")
[[ ! -e $state_dir/container && ! -e $state_dir/process && ! -e $state_dir/owner ]] || {
  echo 'S3 fixture state already exists; stop the owned fixture first.' >&2; exit 1;
}
# Check before creating any process: another local service is never adopted.
if curl --fail --silent --max-time 2 \
  "http://${K_COMMS_TEST_S3_HOST}:${K_COMMS_TEST_S3_PORT}/minio/health/ready" >/dev/null; then
  echo 'An existing service occupies the CI S3 fixture endpoint.' >&2; exit 1
fi
owner=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s\n' "$owner" > "$state_dir/owner"
success=false
cleanup_start() {
  local result=$?
  if [[ $success != true ]]; then
    stop_fixture || result=1
  fi
  exit "$result"
}
trap cleanup_start EXIT

export MINIO_ROOT_USER=$K_COMMS_TEST_S3_ROOT_USER
export MINIO_ROOT_PASSWORD=$K_COMMS_TEST_S3_ROOT_PASSWORD
export MINIO_KMS_SECRET_KEY=$K_COMMS_TEST_S3_KMS_SECRET_KEY
export S3_APP_ACCESS_KEY_ID=$K_COMMS_TEST_S3_ACCESS_KEY_ID
export S3_APP_SECRET_ACCESS_KEY=$K_COMMS_TEST_S3_SECRET_ACCESS_KEY
export S3_BUCKET=$K_COMMS_TEST_S3_BUCKET
export S3_ENDPOINT="http://${K_COMMS_TEST_S3_HOST}:${K_COMMS_TEST_S3_PORT}"

# Only registry pull failure enables the source fallback. Runtime, readiness,
# provisioning and policy errors fail the same required backend check.
if docker pull "$minio_image" > "$state_dir/minio-pull.log" 2>&1 &&
   docker pull "$mc_image" > "$state_dir/mc-pull.log" 2>&1; then
  echo 'Starting the pinned MinIO container fixture.'
  id=$(docker run --detach --pull never --name "k-comms-ci-minio-${owner:0:12}" \
    --label "org.k-comms.ci-s3-owner=$owner" \
    --publish "127.0.0.1:${K_COMMS_TEST_S3_PORT}:9000" \
    --env MINIO_ROOT_USER --env MINIO_ROOT_PASSWORD --env MINIO_KMS_SECRET_KEY \
    --env MINIO_BROWSER=off "$minio_image" server /data)
  [[ $id =~ ^[a-f0-9]{64}$ ]]
  printf '%s\n' "$id" > "$state_dir/container"
  mode=container
else
  echo 'Pinned image pull failed; building checksum-verified upstream release sources.'
  K_COMMS_CI_S3_CACHE_DIR="$cache_dir" bash "$script_dir/build_ci_s3_fixture.sh"
  mkdir "$state_dir/data-$owner"
  binary="$cache_dir/bin/minio"
  # Unset the Actions runner's process-tracking token for this fixture only;
  # the always() cleanup step owns its lifetime across workflow steps.
  env -u RUNNER_TRACKING_ID MINIO_BROWSER=off nohup "$binary" server \
    --address "127.0.0.1:$K_COMMS_TEST_S3_PORT" "$state_dir/data-$owner" \
    > "$state_dir/minio.log" 2>&1 < /dev/null &
  pid=$!
  started=$(awk '{print $22}' "/proc/$pid/stat")
  printf '%s %s %s\n' "$pid" "$started" "$binary" > "$state_dir/process"
  mode=native
fi

ready=false
for _ in {1..30}; do
  if [[ $mode == native ]]; then
    # nohup/env exec the binary asynchronously; allow their initial exec but
    # never accept readiness from an unrelated process at the same endpoint.
    for _ in {1..10}; do
      owned_pid "$pid" "$started" "$binary" && break
      [[ -e /proc/$pid ]] || break
      sleep 0.1
    done
    owned_pid "$pid" "$started" "$binary" || {
      echo 'The owned native S3 fixture exited before readiness.' >&2; exit 1;
    }
  else
    [[ $(docker inspect --format '{{.State.Running}}' "$id") == true ]] || {
      echo 'The owned S3 container exited before readiness.' >&2; exit 1;
    }
  fi
  if curl --fail --silent --max-time 2 "$S3_ENDPOINT/minio/health/ready" >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
[[ $ready == true ]] || { echo 'S3 fixture readiness failed.' >&2; exit 1; }

if [[ $mode == container ]]; then
  docker run --rm --pull never --network host \
    --env MINIO_ROOT_USER --env MINIO_ROOT_PASSWORD \
    --env S3_APP_ACCESS_KEY_ID --env S3_APP_SECRET_ACCESS_KEY \
    --env S3_BUCKET --env S3_ENDPOINT \
    --volume "$script_dir/provision_ci_s3_fixture.sh:/fixture/provision.sh:ro" \
    --entrypoint /bin/sh "$mc_image" /fixture/provision.sh
else
  PATH="$cache_dir/bin:$PATH" MC_CONFIG_DIR="$state_dir/mc-$owner" \
    sh "$script_dir/provision_ci_s3_fixture.sh"
fi
success=true
echo "S3 integration fixture is ready ($mode)."
