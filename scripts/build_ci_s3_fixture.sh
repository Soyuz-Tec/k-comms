#!/usr/bin/env bash
# The image registry can refuse anonymous pulls. Build the same upstream releases
# from verified immutable source archives instead; this never changes production.
set -euo pipefail
umask 077

cache_dir=${K_COMMS_CI_S3_CACHE_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is required}/k-comms-s3-build}
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
  echo 'The CI S3 source fixture requires Linux amd64.' >&2
  exit 1
}
mkdir -p "$cache_dir/archives" "$cache_dir/bin"
cache_dir=$(realpath "$cache_dir")

verified_archive() {
  local name=$1 url=$2 digest=$3 target="$cache_dir/archives/$1" temporary
  if [[ ! -f $target ]]; then
    temporary=$(mktemp "$cache_dir/archives/.download.XXXXXX")
    if ! curl --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 3 --max-time 180 --output "$temporary" "$url"; then
      rm -f "$temporary"
      return 1
    fi
    if ! printf '%s  %s\n' "$digest" "$temporary" | sha256sum --check --status; then
      rm -f "$temporary"
      echo "Checksum verification failed for $name." >&2
      return 1
    fi
    mv "$temporary" "$target"
  fi
  printf '%s  %s\n' "$digest" "$target" | sha256sum --check --status || {
    echo "Checksum verification failed for cached $name." >&2
    return 1
  }
}

verified_archive go.tar.gz https://go.dev/dl/go1.26.8.linux-amd64.tar.gz \
  d0f743b33e8d8945e6b1f432edd15785c70507121d6e2a723b21285eddf8b57b
# The URL uses the immutable annotated tag object; CommitID below is its
# independently verified peeled commit, not the annotated tag object's ID.
verified_archive minio.tar.gz \
  https://codeload.github.com/minio/minio/tar.gz/01ce918d8279a20e4706b96a64396146894adee4 \
  8b11129f6a6830768bcdebab569290ad956618f5ff6ef4857b633acb64f95126
verified_archive mc.tar.gz \
  https://codeload.github.com/minio/mc/tar.gz/d6541ea280b73a834b64d4097e21f2be77676104 \
  4cea8ed209c8f96e59ea1a5cc4901019b54c2be6d6f5f16c6749ea8bdcf4172e

# Re-extract verified archives even on a cache hit. Cached source trees or
# executables are never accepted as a substitute for source verification.
build_dir=$(mktemp -d "$cache_dir/.build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
for name in go minio mc; do
  mkdir "$build_dir/$name"
  tar --extract --gzip --no-same-owner --no-same-permissions \
    --strip-components=1 --file "$cache_dir/archives/$name.tar.gz" \
    --directory "$build_dir/$name"
done
export PATH="$build_dir/go/bin:$PATH"
export GOROOT="$build_dir/go" GOOS=linux GOARCH=amd64
export GOENV=off GOTOOLCHAIN=local GOFLAGS= CGO_ENABLED=0
export GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org
export GOPRIVATE= GONOPROXY= GONOSUMDB= GOINSECURE=
export GOPATH="$cache_dir/gopath"
export GOMODCACHE=${K_COMMS_CI_S3_GO_MODULE_CACHE:-"$cache_dir/modules"}
export GOCACHE=${K_COMMS_CI_S3_GO_BUILD_CACHE:-"$cache_dir/go-build"}
export GOMAXPROCS=3
[[ $(go version) == 'go version go1.26.8 linux/amd64' ]]

build_release() {
  local name=$1 version=$2 release=$3 commit=$4
  (
    cd "$build_dir/$name"
    # Readonly go.mod/go.sum and the public checksum database remain mandatory.
    timeout 600 go build -mod=readonly -buildvcs=false -p 3 -tags kqueue -trimpath \
      -ldflags "-s -w -X github.com/minio/$name/cmd.Version=$version -X github.com/minio/$name/cmd.ReleaseTag=$release -X github.com/minio/$name/cmd.CommitID=$commit" \
      -o "$build_dir/$name.bin" .
    go mod verify
  )
  "$build_dir/$name.bin" --version | grep -F "commit-id=$commit" >/dev/null
  "$build_dir/$name.bin" --version | grep -F "$release" >/dev/null
  chmod 755 "$build_dir/$name.bin"
  mv "$build_dir/$name.bin" "$cache_dir/bin/$name"
}

build_release minio 2025-09-07T16:13:09Z RELEASE.2025-09-07T16-13-09Z \
  07c3a429bfed433e49018cb0f78a52145d4bedeb
build_release mc 2025-08-13T08:35:41Z RELEASE.2025-08-13T08-35-41Z \
  7394ce0dd2a80935aded936b09fa12cbb3cb8096
echo 'Verified MinIO and mc source fixtures built successfully.'
