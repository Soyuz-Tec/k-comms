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
8. stops and verifies the packaged application is quiesced, then runs the
   candidate image's forward migrations through the isolated Ecto migration
   pool with a 5-second PostgreSQL lock timeout and an 8-minute statement
   timeout;
9. starts the packaged application with no source mount; and
10. waits for readiness, the packaged `/app/`, MinIO, LiveKit, both call
    capabilities, and guest-link availability.

Open `http://127.0.0.1:4188/app/?setup=workspace` to land directly on the
local **Create development workspace** flow. The server still decides whether
bootstrap is enabled; the URL does not bypass that control.

Override ports only when needed:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Deploy -AppPort 4288 -MinioPort 6900 -MinioConsolePort 6901 `
  -LiveKitSignalPort 8980 -LiveKitTcpPort 8981 -LiveKitUdpPort 8982
```

## One-command packaged browser and media qualification

After a default-port `Deploy` or `Start` succeeds, qualify the sealed release
and its real media plane with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/qualify_local_release.ps1
```

The qualifier is intentionally fixed to `http://127.0.0.1:4188`. It first
proves that the running application image matches the retained immutable
release receipt. It then checks:

1. `/health/live` reports `ok`;
2. `/health/ready` reports ready database/runtime checks and configured object
   storage;
3. `/api/v1/status` reports an operational service with administration,
   realtime, audio-call, video-call, and guest-link capabilities available;
4. `/app/` is packaged HTML that references built `/app/assets/` files rather
   than Vite/source assets; and
5. `/app/` returns the exact strict local-release Content Security Policy,
   including the sealed LiveKit and object-storage origins and no
   `unsafe-inline`, `unsafe-eval`, or wildcard source.

Finally it runs only `e2e/live-audio.spec.ts` and
`e2e/live-video.spec.ts`, in that order, through Chromium with one Playwright
worker against the external packaged server. Those tests provision disposable
workspaces and prove real microphone RTP, camera RTP, group calls, screen
sharing, access revocation, and clean call teardown. Install the committed web
dependencies and Playwright Chromium before running the qualifier:

```powershell
Set-Location clients/web
npm ci
npx playwright install chromium
Set-Location ../..
```

The packaged qualifier does not run the mocked navigation, UI, or Axe suites.
Those remain source-client gates (`npm run test:e2e`) because their API route
mocks and style injection are deliberately incompatible with validating a
real packaged server and its enforced CSP.

The guest-link browser contract is covered by the deterministic
`e2e/guest-communication.spec.ts` source-client gate. It proves that a host can
create one exact fragment link and QR code, the anonymous entry route scrubs
the secret from browser-visible navigation, a guest joins with only a display
name, messaging stays on the guest-scoped API, account creation remains
optional, and the flow fits a 320 px viewport. Run the focused check with:

```powershell
Set-Location clients/web
npx playwright test e2e/guest-communication.spec.ts --project=chromium
Set-Location ../..
```

This deterministic test remains a fast source-client gate. The sealed-release
qualifier separately runs `e2e/live-guest-communication.spec.ts` against the
exact packaged runtime. Its first case provisions a disposable workspace, uses
the owner browser UI to create a communication-only link and QR code, proves
the QR contains the exact displayed link, opens that link in a clean browser,
proves the fragment secret is scrubbed, joins with only a display name, delivers
a realtime message, and verifies revocation ends both API and socket access.
Tokens and disposable credentials remain in test process memory and are not
printed. A second isolated live case uses the API to create and redeem the
preauthorized single-use fixture, proves a mismatched conversion email fails
closed, converts the same user in place with the exact email, reaches
`/api/v1/me` as a human, and denies the old guest credential.
Real audio and video packet coverage remains in the two live media
specifications described above.

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
candidate once before using it with a legacy receipt. Before activating a
receipt that lacks guest rollback capabilities, `Start` runs the same quiesced
PostgreSQL hazard probe. This fails closed when a migrated failed candidate left
guest rows or jobs while `current.json` still names its legacy predecessor; use
a guest-compatible bridge or roll-forward recovery instead.

`Status` reports both the recorded receipt and the observed application
container state, health, image ID, and image-match result. A recorded receipt
is not presented as current runtime health when the container is stopped,
unhealthy, unavailable, or running another image.

`Rollback` verifies the retained environment, Compose-source, and
rendered-configuration hashes plus the image ID, recreates the application from
the previous candidate's retained Compose source, and repeats health checks. It
never depends on the current checkout's Compose file and never runs a down migration.
The new candidate must report `guest_links: true` before its receipt is sealed,
but restore and rollback intentionally apply only the predecessor's historical
health contract.

Guest identity persistence is an explicit rollback boundary. Every new receipt
declares `guest_identity_v1` and `guest_admission_expiry_worker_v1`. Before
restoring a retained predecessor that lacks either declaration, the release
manager quiesces the current application before the final probe, verifies it is
stopped, and then queries PostgreSQL for `account_type = 'guest'` rows and active
`CommsWorkers.GuestAdmissionExpiryWorker` jobs. No guest transaction can commit
between that probe and predecessor startup. Rollback is blocked when either
exists, because that predecessor cannot safely decode the persisted enum or
execute the scheduled worker. The error reports both counts and directs the
operator to retain or deploy a guest-compatible bridge release, or roll forward;
it never deletes or rewrites guest data.

When an operator-requested rollback is blocked or the probe fails, the manager
restarts and health-checks the exact current receipt only when that receipt
declares guest compatibility. `Rollback` is an activating recovery operation,
so this compatible current release is restarted even if it was stopped before Rollback;
run `Stop` again after reviewing the failure if it should remain stopped. If the
recorded current receipt is itself legacy—possible after a migrated candidate
failed before its receipt was sealed—the manager must not start it and leaves
the application quiesced for bridge or roll-forward recovery. If predecessor
startup itself fails after a clear zero-hazard probe, the manager can safely
restore and health-check the exact current receipt and reports both outcomes.
When a newly deployed candidate has already migrated but fails
qualification, an unsafe or inconclusive legacy-predecessor probe intentionally
leaves that failed candidate quiesced and preserves all data for roll-forward
recovery instead of starting incompatible code.

The `Validate` action executes both health-capability shapes and the rollback
compatibility matrix: it accepts an otherwise healthy predecessor without
`guest_links`, rejects the same payload as a candidate, accepts a candidate only
when the capability is explicitly true, permits a legacy predecessor only when
no guest state exists, and permits persisted guest state only for a
guest-compatible predecessor.
If a new candidate fails after migration or startup, Deploy applies the same
quiesced hazard guard before attempting the previous-application restore. When
the first-ever candidate fails, Deploy stops and removes every candidate service
and verifies no candidate container remains while retaining named volumes and
failure evidence.

Because rollback retains the forward schema, every migration must follow the
expand-contract and one-release compatibility rules in
[`release-strategy.md`](release-strategy.md).
Migration failure is not retried blindly: the retained application is restored
when safe, while the failure receipt and migration output remain available for
investigation before a deliberate rerun.

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
media-capable; use the one-command packaged qualifier above.

On Podman Desktop, LiveKit binds the explicit mapped TCP and UDP ports while
advertising `127.0.0.1`. Do not enable LiveKit's separate
`rtc.enable_loopback_candidate` option: real-browser qualification showed that
it prevents the mapped TCP candidate from being selected. The release policy
validator rejects that flag.

External HTTPS/WSS, TURN/TLS, managed state, multi-zone resilience, provider approval,
signed publication attestations, security approval, accessibility studies,
and on-call readiness remain outside this qualification.
