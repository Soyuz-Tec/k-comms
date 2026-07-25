# Immutable local release qualification

This path runs the packaged Phoenix/OTP release and built React client against
isolated local PostgreSQL, MinIO, and LiveKit services. It does not use source
bind mounts or Vite, and it does not replace or stop the development Compose
project. In the supported manager path, Podman always publishes the packaged
application, object-storage API, and media ports on `127.0.0.1`. For controlled
private-LAN evaluation, the manager can run a receipt-bound Windows host
forwarder on one exact locally assigned RFC1918 IPv4 address. Neither mode
permits Podman publication on `0.0.0.0` or directly on an RFC1918 address. A
LAN address on a Windows network profile other than **Private** fails closed
unless the operator supplies the explicit audited
`-AllowPublicNetworkProfile` override.

## Prerequisites

- Windows PowerShell 5.1 or newer
- Git, `tar`, Python 3, Podman, and a Compose provider
- for manager lifecycle actions, Node.js only when LAN mode or the forwarder
  self-test is selected; loopback deploy/start/status/stop remains Node-free
- Node.js/npm and Playwright Chromium for the separate packaged browser
  qualifier, including default loopback qualification (installation below)
- a completely clean worktree at the exact candidate revision
- free loopback ports `4188`, `5900`, `5901`, `7980`, `7981`, and `7982`
- for LAN mode, free ports `4188`, `5900`, `7980`, `7981`, and `7982` on the
  selected RFC1918 address for the host forwarder
- a Windows **Private** network profile for LAN mode, or an explicit risk
  acceptance using `-AllowPublicNetworkProfile`

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
   six candidate ports are unique and available on loopback unless the
   currently recorded release owns them; LAN mode separately preflights its
   five selected-address forwarder ports;
2. creates and hashes a retained `git archive`, verifies `HEAD` before and
   after capture, and extracts an isolated build context;
3. builds `Dockerfile` target `runtime` from that immutable context once as
   `localhost/k-comms:sha-<full-sha>-<attempt-id>` so a repeated deployment of
   the same revision cannot move a predecessor's image tag;
4. verifies `HEAD` again, verifies the image's OCI revision label, and records
   its ID/digest;
5. hashes the retained release environment and candidate Compose source, then
   renders and hashes the exact release configuration from that retained copy;
6. starts isolated data and media services with Podman publications fixed to
   `127.0.0.1`;
7. initializes the versioned object bucket;
8. stops and verifies the packaged application is quiesced, then runs the
   candidate image's forward migrations through the isolated Ecto migration
   pool with a 5-second PostgreSQL lock timeout and an 8-minute statement
   timeout;
9. starts the packaged application with no source mount; and
10. waits for readiness, the packaged `/app/`, MinIO, LiveKit, both call
    capabilities, and guest-link availability through loopback; LAN mode then
    starts the retained forwarder, validates its ready identity/configuration
    hash/listeners, and probes the selected public address.

Open `http://127.0.0.1:4188/app/?setup=workspace` to land directly on the
local **Create development workspace** flow. The server still decides whether
bootstrap is enabled; the URL does not bypass that control.

## Explicit private-LAN access

To let another device on the same trusted private network open K-Comms, select
the server's real, active RFC1918 IPv4 address and deploy that exact address:

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object {
    $_.AddressState -eq "Preferred" -and
    $_.IPAddress -notlike "127.*"
  } |
  Select-Object InterfaceAlias, IPAddress

powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Deploy -BindAddress 192.168.1.25
```

Replace `192.168.1.25` with an address shown for the active LAN adapter. The
manager verifies that it is canonical RFC1918 space and that Windows reports
it as exactly `Preferred` on exactly one local interface before building or
changing the release. Tentative, Duplicate, Deprecated, and all other address
states fail closed. The manager also requires exactly one observable Windows
network profile for that interface.

Keep the selected server address stable by reserving it in DHCP/router policy
or by using another correctly administered fixed assignment. The receipt
intentionally pins that exact address and interface: after a lease change,
adapter change, or reboot that moves the address, Start and Status fail their
topology check instead of silently publishing on the new IP. Deploy a new
receipt only after the intended replacement address is stable.

Open:

```text
http://192.168.1.25:4188/app/
```

The selected address becomes the exact Phoenix public host, CORS origin,
WebSocket origin, MinIO browser endpoint, LiveKit advertised node IP, external
probe address, and receipt topology. It does **not** become a Podman bind
address. Compose receives `K_COMMS_PODMAN_BIND_ADDRESS=127.0.0.1`, and all five
LAN-facing ports are owned by the retained
`scripts/lan_release_forwarder.mjs` host process. That process forwards the
same-number TCP/UDP ports from the selected RFC1918 address to
`127.0.0.1`.

For every manager-owned Compose call, all retained and referenced interpolation
variables are temporarily scoped to the retained environment. Referenced
variables absent from that file are cleared, the Podman bind is forced to
`127.0.0.1`, and the caller's process environment is restored afterward. An
ambient shell value such as `K_COMMS_PODMAN_BIND_ADDRESS=0.0.0.0` therefore
cannot widen the retained publication or rewrite its public-host settings.
Direct `podman compose` use is not a supported release path: it bypasses the
manager's operation lock, retained receipt, topology validation, and sealed
environment. Do not invoke either the checkout or retained Compose file
directly.

`Start` and `Rollback` use the public address sealed in their retained receipt
rather than the current command line. They fail before activation if the
address, interface index/alias, network name, or profile category no longer
matches, or if the address is no longer exactly `Preferred`. Local dependency
and application health are proved through `127.0.0.1` before the forwarder can
become ready. The manager then requires the current process identity,
readiness token, configuration hash, and exact five-listener set to match the
receipt before probing the public address.

`Status` re-observes the Windows network facts and prints
`Observed network topology matches receipt: True` only for an exact match. A
healthy LAN release must also print:

```text
Forwarder: ready
Observed forwarder matches receipt: True
Observed forwarder configuration hash matches receipt: True
```

Loopback status instead prints `Forwarder: not-required`. These are
qualification gates, not informational-only messages.

If Windows reports the selected adapter as **Public** (or another non-Private
category), the default command stops before building. For a deliberately
authorized, controlled evaluation only, repeat the command with the explicit
override:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Deploy -BindAddress 192.168.1.25 -AllowPublicNetworkProfile
```

The schema-v5 receipt records the observed interface, network name/category,
override authorization, whether it was needed, the fixed Podman bind, exposure
mode, retained forwarder script/config hashes and paths, readiness token, ready
and log paths, and exact listener contract. `Start` and `Rollback` reuse the
audited authorization but still re-observe and compare the exact interface and
profile before activating containers. The override does not make a Public
network trusted and does not expand this clear-text evaluation into a
production profile.

Only the forwarder's application (`4188` TCP), browser-facing MinIO API
(`5900` TCP), and LiveKit signaling/media ports (`7980` TCP, `7981` TCP,
`7982` UDP) bind to that exact LAN IP. The corresponding Podman publications
remain on loopback. PostgreSQL remains internal and the MinIO admin console (`5901`) stays loopback-only.

The manager never creates, changes, narrows, validates, or removes Windows Firewall rules. Successful host-local loopback and selected-address probes do
not prove that a second device can connect through the firewall.

The recommended operation is to classify a genuinely trusted LAN as Windows
**Private**, then have an administrator create exact-IP or trusted-subnet
inbound rules for only the five LAN-facing ports above. Never open PostgreSQL
or port `5901`, and never create an all-address/all-profile rule.

If an operator deliberately keeps the interface on the Windows **Public**
profile and uses `-AllowPublicNetworkProfile`, any separately administered
firewall rule must explicitly scope **Profile Public**, the exact local
IP/interface, the trusted remote subnet, and only those five ports. The
override does not create such a rule or make the network trusted. Remote
qualification remains pending until an authorized second device proves the
expected connection; local probes alone must not be reported as LAN
reachability.

This LAN mode is clear-text evaluation, not a production deployment. Browsers
normally treat microphone, camera, screen capture, service workers, and other
sensitive APIs as secure-context features. Qualification of
`http://<LAN-IP>` is therefore always text-only and never claims browser
audio/video media. Use a trusted HTTPS/WSS ingress with a certificate valid for
the chosen hostname, plus proper TURN/TLS when clients cross NAT or network
boundaries, before claiming reliable media or production security.

HTTP/WS LAN traffic is also vulnerable to on-path observation and
modification. That includes authentication, session, and join tokens, message
content, and file links. Use this mode only for controlled evaluation on a
trusted network with no sensitive data. Trusted HTTPS/WSS is mandatory for any
internal-production use, independently of whether browser media is enabled.

`Forwarder: ready` proves the Node UDP listener, receipt identity,
configuration hash, and host-side ownership. It does **not** prove that
Windows `127.0.0.1:7982` reaches LiveKit through Podman/WSL. On the evaluated
host no Windows UDP endpoint was observable and the STUN probe failed.
Therefore never infer media capability from forwarder readiness. Future LAN
media qualification requires either a live, selected TCP fallback path or a
demonstrably solved UDP bridge across the Windows-to-WSL boundary, followed by
real browser media tests.

Override ports only when needed:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Deploy -AppPort 4288 -MinioPort 6900 -MinioConsolePort 6901 `
  -LiveKitSignalPort 8980 -LiveKitTcpPort 8981 -LiveKitUdpPort 8982
```

## One-command packaged browser and media qualification

After a default loopback `Deploy` or `Start` succeeds, qualify the sealed
release and its real media plane with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/qualify_local_release.ps1
```

The default qualifier targets `http://127.0.0.1:4188`. It first
proves that the running application image matches the retained immutable
release receipt and that the current address/interface/profile still matches
that receipt. Loopback additionally requires `Forwarder: not-required`. LAN
requires a schema-v5 receipt and the current forwarder ready, identity-match,
and configuration-hash-match status lines shown above. The supplied `-BaseUri`
is an expected origin only: it must equal the receipt's exact public
application origin. The qualifier reads the app, LiveKit signaling, and MinIO
API ports from `deployment.json` and builds its expected CSP origins from those
sealed values, including when non-default ports were deployed. It then checks:

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

Finally it runs `e2e/live-guest-communication.spec.ts` through Chromium
against the external packaged server. Loopback qualification then runs
`e2e/live-audio.spec.ts` and `e2e/live-video.spec.ts`, in that order, with one
Playwright worker. The media tests provision disposable workspaces and prove
real microphone RTP, camera RTP, group calls, screen sharing, access
revocation, and clean call teardown. LAN text-only qualification stops after
the guest test and never makes those media claims. Install the committed web
dependencies and Playwright Chromium before running the qualifier:

```powershell
Set-Location clients/web
npm ci
npx playwright install chromium
Set-Location ../..
```

For a plain HTTP RFC1918 origin, use the explicit text-only LAN qualification:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/qualify_local_release.ps1 `
  -BaseUri http://192.168.1.25:4188 `
  -LanTextOnly
```

`-LanTextOnly` is rejected for loopback and is mandatory for every
non-loopback RFC1918 HTTP origin. LAN qualification still proves the retained
image/receipt, current forwarder identity/readiness/hash, health, status
capabilities, packaged assets, CSP, instant-room endpoint, and live guest
communication flow, but it intentionally skips the audio and video
specifications. Its final output states that media was **not qualified**. A
default loopback qualification cannot opt out of media and continues to
require both real audio and video gates.

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
- `deployment.json` with revision, image ID/digest, exact bind/public-host
  topology, observed Windows interface/profile, any audited non-Private-profile
  override, fixed Podman bind, exposure mode, forwarder evidence, ports,
  migration result, configuration hash, and predecessor;
- the exact `source.archive.tar` used as the image build context and its
  SHA-256 hash;
- the exact `compose.source.yaml` used by that candidate and its SHA-256 hash;
- the exact `compose.rendered.yaml`;
- a safe-to-review `compose.rendered.redacted.yaml`;
- for LAN mode, the retained forwarder script, its exact JSON configuration,
  SHA-256 hashes, atomic ready record, and stdout/stderr logs; and
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

`Stop` stops the exact receipt-matching LAN forwarder before the Compose
runtime, then retains images, receipts, PostgreSQL data, MinIO data, forwarder
evidence, and configuration. It never kills an unrelated Node process.

`Start` verifies the recorded environment, Compose, rendered configuration,
source-archive hashes, image revision label, image ID, image digest, and any
required forwarder script/configuration hashes. It then starts only the
currently recorded immutable release from its retained Compose and
environment, reruns the same forward-only migration command (normally a no-op
for an already-current database), recreates the packaged application, and
repeats loopback health checks. For LAN mode it safely replaces the managed
forwarder, verifies its current ready identity/hash/listeners, and only then
probes the public address. It does not require a clean checkout, read the
checkout Compose file, or rebuild an image.

`Start` accepts schema-v3 and schema-v4 receipts only for loopback
compatibility. Current deployments write schema v5 with the audited
network-profile, loopback Podman bind, exposure mode, and forwarder record.
Deploy a clean candidate once before using LAN mode with a legacy receipt.
Before activating a receipt that lacks guest rollback capabilities, `Start`
runs the same quiesced PostgreSQL hazard probe. This fails closed when a
migrated failed candidate left guest rows or jobs while `current.json` still
names its legacy predecessor; use a guest-compatible bridge or roll-forward
recovery instead.

`Status` reports both the recorded receipt and the observed application
container state, health, image ID, and image-match result. It also reports
`Forwarder: not-required` for loopback or, for LAN, the current forwarder
readiness plus receipt-identity and configuration-hash matches. A recorded
receipt is not presented as current runtime health when the container is
stopped, unhealthy, unavailable, running another image, or paired with a stale
or mismatched LAN forwarder.

`Rollback` verifies the retained environment, Compose-source,
rendered-configuration, forwarder-script, and forwarder-configuration hashes
plus the image ID. It recreates the application from the previous candidate's
retained Compose source, starts that receipt's matching forwarder when
required, and repeats local and public health checks. It never depends on the
current checkout's Compose or forwarder files and never runs a down migration.
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
loopback or exact private-LAN topology. The runtime also requires
`ALLOW_DEVELOPMENT_ADAPTERS=true`, the selected exact public HTTP/WS origins,
and the internal API origin `http://livekit:7880`. Compose additionally
requires `K_COMMS_PODMAN_BIND_ADDRESS=127.0.0.1`; the selected public host is
never substituted into a Podman `ports` entry. A LAN selection additionally
requires the exact guarded `K_COMMS_LOCAL_RELEASE_HOST`, a matching observed
Windows interface/profile receipt, a schema-v5 retained forwarder, and either
a Private profile or the explicit audited non-Private-profile override.
Missing, public-IP, unassigned, wildcard, directly published RFC1918, stale
forwarder, or broader combinations fail closed.

This proves local packaging, migration, dependency startup, application
readiness, immutable restart, and application rollback. The HTTP checks prove
LiveKit signaling availability, not successful WebRTC media packets. External
browser media tests are therefore required before calling the release
media-capable. A `-LanTextOnly` result is deliberately not media qualification;
use the full loopback qualifier or trusted HTTPS/WSS media qualification before
making that claim.

On Podman Desktop, LiveKit's published TCP and UDP ports remain on
`127.0.0.1` while `--node-ip` advertises the selected loopback or RFC1918
public host. In LAN mode the managed host forwarder owns the selected-address
TCP/UDP listeners and relays them to those loopback publications. Do not enable
LiveKit's separate `rtc.enable_loopback_candidate` option: real-browser
qualification showed that it prevents the mapped TCP candidate from being
selected. The release policy validator rejects that flag.

The release manager starts, verifies, replaces, and stops the receipt-bound
forwarder during lifecycle actions; it does not continuously supervise it as a
Windows service. If the process exits unexpectedly, Status reports it as not
ready and qualification fails. Run Start to recover the exact retained release
and forwarder. Automatic crash restart remains an operations gap.

External HTTPS/WSS, TURN/TLS, managed state, multi-zone resilience, provider approval,
signed publication attestations, security approval, accessibility studies,
and on-call readiness remain outside this qualification.
