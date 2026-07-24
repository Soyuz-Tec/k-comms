# Immutable local release qualification

This path runs the packaged Phoenix/OTP release and built React client against
isolated local PostgreSQL, MinIO, and LiveKit services. It does not use source
bind mounts or Vite, and it does not replace or stop the development Compose
project.

## Prerequisites

- Windows PowerShell 5.1 or newer
- Git, `tar`, Python 3, Podman, and a Compose provider
- a completely clean worktree at the exact candidate revision
- free loopback ports `4188`, `5900`, `5901`, `7980`, `7981`, and `7982`

Validate the static policy and rendered Compose contract without deploying:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Validate
```

## One-action deploy

Commit the candidate, then run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Deploy
```

The command performs the complete local release transaction:

1. proves the worktree is clean, resolves the full Git SHA, and checks that all
   six candidate ports are unique and available unless the currently recorded
   release owns them;
2. creates and hashes a retained `git archive`, verifies `HEAD` before and
   after capture, and extracts an isolated build context;
3. builds `Dockerfile` target `runtime` from that immutable context once as
   `localhost/k-comms:sha-<full-sha>-<attempt-id>` so a repeated deployment of
   the same revision cannot move a predecessor's image tag;
4. verifies `HEAD` again, verifies the image's OCI revision label, and records
   its ID/digest;
5. hashes the retained release environment and candidate Compose source, then
   renders and hashes the exact release configuration from that retained copy;
6. starts isolated data and media services;
7. initializes the versioned object bucket;
8. runs the candidate image's forward migrations;
9. starts the packaged application with no source mount; and
10. waits for readiness, the packaged `/app/`, MinIO, LiveKit, and both call
   capabilities.

Open `http://127.0.0.1:4188/app/?setup=workspace` to land directly on the
local **Create development workspace** flow. The server still decides whether
bootstrap is enabled; the URL does not bypass that control.

Override ports only when needed:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Deploy -AppPort 4288 -MinioPort 6900 -MinioConsolePort 6901 `
  -LiveKitSignalPort 8980 -LiveKitTcpPort 8981 -LiveKitUdpPort 8982
```

## Evidence and secret handling

The default state directory is:

```text
%LOCALAPPDATA%\K-Comms\local-release
```

The operator creates this directory itself, writes a canonical-path and
Compose-project ownership marker, and only then protects it with a
current-user-only ACL. It refuses existing unmarked directories, filesystem
roots, user-profile/system state roots, repository ancestors, and reparse
points before changing any ACL. For a custom `-StateRoot`, provide a path that
does not yet exist or reuse a path already carrying the matching K-Comms
ownership marker. Every existing ancestor of a custom path is inspected, and
the command refuses a path that traverses a junction or other reparse point.
Never add that marker manually to adopt an existing directory.

Mutating actions also hold an exclusive state-file lock and a Compose-project
mutex. A second Deploy, Start, Rollback, or Stop action fails immediately
instead of racing migrations, containers, or `current.json`.

The protected state contains:

- a stable local-secret environment used by the isolated data volumes plus a
  hash-bound per-candidate release environment;
- one history directory per attempted candidate;
- `deployment.json` with revision, image ID/digest, ports, migration result,
  configuration hash, and predecessor;
- the exact `source.archive.tar` used as the image build context and its
  SHA-256 hash;
- the exact `compose.source.yaml` used by that candidate and its SHA-256 hash;
- the exact `compose.rendered.yaml`;
- a safe-to-review `compose.rendered.redacted.yaml`; and
- migration/failure/rollback receipts.

Do not copy the unredacted environment or rendered configuration into the
repository, tickets, chat, or CI artifacts. The script rejects a state path
inside the repository.

## Status, start, stop, and rollback

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Start
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Stop
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Rollback
```

`Stop` retains images, receipts, PostgreSQL data, MinIO data, and configuration.
`Start` verifies the recorded environment, Compose, rendered configuration,
source-archive hashes, image revision label, image ID, and image digest. It
then starts only the currently recorded immutable release from its retained
Compose and environment, reruns the same forward-only migration command
(normally a no-op for an already-current database), recreates the packaged
application, and repeats all health checks. It does not require a clean
checkout, read the checkout Compose file, or rebuild an image. `Start` accepts
only schema-v3 receipts that bind the retained source archive; deploy a clean
candidate once before using it with a legacy receipt.

`Status` reports both the recorded receipt and the observed application
container state, health, image ID, and image-match result. A recorded receipt
is not presented as current runtime health when the container is stopped,
unhealthy, unavailable, or running another image.

`Rollback` verifies the retained environment, Compose-source, and
rendered-configuration hashes plus the image ID, recreates the application from
the previous candidate's retained Compose source, and repeats health checks. It
never depends on the current checkout's Compose file and never runs a down migration.
If a new candidate fails after migration or startup, Deploy automatically
attempts the same previous-application restore. When the first-ever candidate
fails, Deploy stops and removes every candidate service and verifies no
candidate container remains while retaining named volumes and failure
evidence.

Because rollback retains the forward schema, every migration must follow the
expand-contract and one-release compatibility rules in
[`release-strategy.md`](release-strategy.md).

## Qualification boundary

`K_COMMS_LOCAL_RELEASE=true` is a deliberately narrow exception for this
loopback topology. The runtime also requires
`ALLOW_DEVELOPMENT_ADAPTERS=true`, loopback-only public HTTP/WS origins, and the
internal API origin `http://livekit:7880`. Missing or broader combinations fail
startup.

This proves local packaging, migration, dependency startup, application
readiness, immutable restart, and application rollback. The HTTP checks prove
LiveKit signaling availability, not successful WebRTC media packets. External
browser media tests are therefore required before calling the release
media-capable.

On Podman Desktop, LiveKit binds the explicit mapped TCP and UDP ports while
advertising `127.0.0.1`. Do not enable LiveKit's separate
`rtc.enable_loopback_candidate` option: real-browser qualification showed that
it prevents the mapped TCP candidate from being selected. The release policy
validator rejects that flag.

External HTTPS/WSS, TURN/TLS, managed state, multi-zone resilience, provider approval,
signed publication attestations, security approval, accessibility studies,
and on-call readiness remain outside this qualification.
