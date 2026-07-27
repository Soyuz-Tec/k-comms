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
`-AllowPublicNetworkProfile` override. The separate
`cloudflare_trusted_edge` profile can terminate public HTTPS/WSS at Cloudflare
Tunnel while keeping application, signaling, and object origins on loopback.
It exposes only LiveKit ICE media on the selected LAN address and is a
same-LAN qualification profile, not a remote-media or production profile.

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
- for the trusted-edge profile:
  - `cloudflared` 2025.4.0 or newer, which supports `--token-file`, installed
    as a separately administered Windows service;
  - control of the `avayaworks.com` Cloudflare zone and one named tunnel;
  - published routes for the three exact hostnames documented below;
  - valid Cloudflare edge certificates and working public DNS for those names;
  - an elevated operator session for the dedicated Windows service and
    separately administered firewall rules;
  - free `7981/TCP` and `7982/UDP` listeners on the exact media-node address;
    and
  - a stable DHCP reservation or administered fixed assignment for
    `192.168.1.177`

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
   five selected-address forwarder ports, while trusted-edge mode preflights
   only `7981/TCP` and `7982/UDP` on its selected media address;
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
9. provisions the fixed instant-room tenant through the exact image's
   PostgreSQL-serialized `CommsCore.Release.bootstrap()` one-shot service,
   verifies the active-tenant postcondition, and never calls the public
   bootstrap HTTP endpoint;
10. starts the packaged application with no source mount and forces
    `ALLOW_BOOTSTRAP=false`, including when activating a retained legacy
    environment; and
11. waits for readiness, the packaged `/app/`, MinIO, LiveKit, both call
    capabilities, and guest-link availability through loopback; LAN mode then
    starts the retained forwarder, validates its ready identity/configuration
    hash/listeners, and probes the selected public address. Trusted-edge mode
    starts and verifies only the two-listener LAN media forwarder, then probes
    the exact public application, signaling, and object origins through the
    already-running, independently administered Cloudflare tunnel.

The local workspace is already provisioned before the application starts.
Open `http://127.0.0.1:4188/sign-in` to sign in on the host, or use `/` to
start an instant room without an account. The public workspace-creation
endpoint stays disabled. The initial owner password remains only in the
current-user-protected local-release state; do not print or copy it into
qualification evidence. Rotate that credential through the application before
using the workspace beyond disposable local testing.

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

The network record introduced in schema v5 and retained by current schema v7
records the observed interface, network name/category, override authorization,
whether it was needed, the fixed Podman bind, exposure mode, retained forwarder
script/config hashes and paths, readiness token, ready and log paths, and exact
listener contract. `Start` and `Rollback` reuse the audited authorization but
still re-observe and compare the exact interface and profile before activating
containers. The override does not make a Public network trusted and does not
expand this clear-text evaluation into a production profile.

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

## Trusted HTTPS/WSS with Cloudflare and same-LAN media

Use this profile when the pilot browser needs a trusted HTTPS origin for
microphone, camera, or screen capture and all media participants are on the
same trusted LAN. The split topology is intentional:

| Browser endpoint | Cloudflare Tunnel loopback origin | Function |
|---|---|---|
| `https://comms.avayaworks.com` | `http://127.0.0.1:4188` | UI, REST API, and Phoenix WebSocket |
| `wss://media.avayaworks.com` | `http://127.0.0.1:7980` | LiveKit API/signaling only |
| `https://kcomms-files.avayaworks.com` | `http://127.0.0.1:5900` | browser object upload/download |

Cloudflare documents this public-hostname-to-local-service model and supports
multiple public hostnames on one tunnel
([published-application routing](https://developers.cloudflare.com/tunnel/routing/#published-applications)).
The public `wss://` URL is carried through the HTTP route to LiveKit's
loopback signaling listener; do not create a raw TCP route for browsers.
Cloudflare supports proxied WebSocket upgrades, but may terminate connections
during edge-code releases, so existing K-Comms reconnect behavior remains
required
([Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)).

WebRTC media does **not** traverse the Cloudflare routes. LiveKit advertises
direct same-LAN candidates on:

| Listener | Scope |
|---|---|
| `192.168.1.177:7981/TCP` | LiveKit ICE/TCP fallback, trusted LAN only |
| `192.168.1.177:7982/UDP` | LiveKit single-port ICE/UDP mux, trusted LAN only |

LiveKit identifies these as the ICE/TCP fallback and optional single-port UDP
mux ([LiveKit ports and firewall](https://docs.livekit.io/transport/self-hosting/ports-firewall/)).
Cloudflare's standard published-application route is an HTTP/HTTPS path;
non-HTTP routes require a client-side connector or separate products
([Cloudflare supported protocols](https://developers.cloudflare.com/tunnel/routing/#supported-protocols)).
Do not configure or describe the tunnel as a UDP media relay.
The release manager does not create or remove Windows Firewall rules. An
administrator must scope the two inbound media rules to the exact local
address/interface, active Windows profile, and trusted remote subnet; never
open them on every interface or remote address.

### Cloudflare control-plane configuration

In the **Cloudflare One** dashboard, open **Networks > Connectors > Cloudflare
Tunnel**, create or select one K-Comms-dedicated named tunnel, and add exactly
these three published-application routes:

```text
comms.avayaworks.com         -> http://127.0.0.1:4188
media.avayaworks.com         -> http://127.0.0.1:7980
kcomms-files.avayaworks.com  -> http://127.0.0.1:5900
```

The dashboard creates proxied DNS records for routes added there. If DNS is
managed separately, point each proxied CNAME to the same
`<TUNNEL-UUID>.cfargotunnel.com`; never place the UUID or a tunnel token in
source files. Cloudflare's route documentation describes both dashboard-managed
and explicit CNAME setup
([Cloudflare Tunnel DNS records](https://developers.cloudflare.com/tunnel/routing/#dns-records)).

Apply these edge rules before qualification:

1. Confirm from the zone's DNS and application inventory that
   `avayaworks.com` remains dedicated solely to K-Comms. Only after that
   inventory passes, enable zone-wide **Always Use HTTPS** so every visitor
   HTTP request is redirected at the edge. Cloudflare documents that this
   applies to all subdomains and hosts in the zone
   ([Cloudflare Always Use HTTPS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/always-use-https/)).
   If an unrelated HTTP service is later added, replace the zone-wide setting
   with hostname-scoped redirect rules for the three K-Comms names before
   enabling that service.
   In **SSL/TLS > Edge Certificates**, also set **Minimum TLS Version** to
   **TLS 1.2**. Cloudflare documents that this rejects visitor connections
   using older protocol versions
   ([Cloudflare minimum TLS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/minimum-tls/)).
2. In the zone's **Network** settings, set **WebSockets** to **On** and keep
   **Argo Smart Routing** disabled. Phoenix and LiveKit both require WebSocket
   upgrades in this topology, and Cloudflare documents that Argo is not
   compatible with WebSockets
   ([Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)).
3. **No Cloudflare Access login or challenge** may cover
   `comms.avayaworks.com`, the anonymous `/join` journey, its REST calls, its
   Phoenix WebSocket, `media.avayaworks.com` signaling, or signed requests to
   `kcomms-files.avayaworks.com`. If account-wide **Require Access protection**
   is enabled, exempt all three hostnames. An Access prompt would defeat the
   intentionally account-optional invitation flow, and the supporting browser
   SDK requests cannot complete an interactive Access login. Use K-Comms
   guest-link expiry, application authorization, rate limits, WAF, and audit
   controls instead. Put any future Access-protected operations UI on a
   different hostname.
4. Set a hostname-scoped **Bypass cache** rule only for
   `kcomms-files.avayaworks.com`, including its health and signed object
   requests. Keep normal Cloudflare dynamic-content behavior on
   `comms.avayaworks.com` and `media.avayaworks.com`: do not add a
   cache-everything rule for HTML, API/session, bearer invitation, Phoenix
   socket, or LiveKit signaling traffic. Content-hashed `/app/assets/` may use
   normal cache behavior. Cloudflare recommends keeping login and application
   API responses out of cache
   ([Cloudflare dynamic-content guidance](https://developers.cloudflare.com/cache/troubleshooting/dynamic-content-and-login-issues/)).
5. Do not apply an interactive challenge to WebSocket, signed-upload, sign-in,
   or guest-join traffic. Narrow WAF and rate-limit rules so they do not replay
   state-changing requests or break protocol upgrades.
6. Keep each tenant's `max_attachment_bytes` at or below the zone's configured
   maximum upload size. The reference tenant default is `26,214,400` bytes
   (25 MiB). Cloudflare currently documents plan ceilings of 100 MB for
   Free/Pro, 200 MB for Business, and 500+ MB for Enterprise, and notes that
   the zone setting can reduce that ceiling
   ([Cloudflare 413 guidance](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/)).
   A tenant setting above the effective edge ceiling is not qualified: lower
   the K-Comms setting or increase the administered zone limit before allowing
   uploads.
7. Keep the MinIO console (`5901`) and PostgreSQL private. They are not DNS
   records, tunnel routes, or LAN listeners.

The reference-zone check on 2026-07-25 observed **Always Use HTTPS** on,
**Minimum TLS Version** set to **TLS 1.2**, **WebSockets** on, **Argo Smart
Routing** off, and the cache-bypass rule scoped only to
`kcomms-files.avayaworks.com`. A TLS 1.2 public probe succeeded. The apex and
`www` redirect to `https://comms.avayaworks.com` while preserving path and
query. This is a timestamped observation, not durable evidence; repeat the
dashboard and non-secret endpoint checks for every qualification.

Configure the dashboard-generated remotely managed tunnel as a Windows service
using Cloudflare's current service guidance, but make an ACL-protected token
file the normative credential source for this reference host. The final service
definition must use `--token-file <protected-path-outside-the-repository>` and
must not contain an inline `--token` value. The provider-generated credential
is represented here only as `<TUNNEL_TOKEN_FROM_CLOUDFLARE>`; neither a
token-bearing installer command nor the protected path is reproduced.

Run provider credential steps only in an elevated private console. Do not paste
the real command or token into this repository, a persisted shell history,
chat, ticket, deployment receipt, or test output. Keep any token file or
service configuration in an ACL-protected operating-system location outside
the checkout and local-release evidence tree. When invoking current
`cloudflared` outside the service installer, prefer `--token-file`. Cloudflare
documents both the Windows service model and token-file support
([run as a service](https://developers.cloudflare.com/tunnel/advanced/local-management/as-a-service/),
[tunnel token parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/#token-file)).
The release manager never creates, updates, starts, stops, or authenticates the
Cloudflare tunnel. Keep this connector dedicated to K-Comms so its availability
and incident decisions do not affect unrelated published applications. A
trusted administrator must privately inspect the service configuration after
installation or recovery and record only that token-file use and ACL posture
passed; never print or copy the command line into qualification evidence.

The `avayaworks.com` reference routes are administered as a dedicated
connector, and its Windows service is configured for automatic startup and
restart on failure. Verify that posture without printing its command line or
registry image path:

```powershell
Get-CimInstance Win32_Service -Filter "Name='cloudflared'" |
  Select-Object Name, State, StartMode
sc.exe qfailure cloudflared
```

The expected service state is `Running`, start mode `Auto`, with a configured
failure-restart action. These checks intentionally do not display the service
command because a remotely managed tunnel token can be present there.

The Cloudflare zone administrator owns the tunnel credential lifecycle. Rotate
the remotely managed tunnel token on the organization's normal secret-rotation
cadence and immediately after suspected disclosure. Because this pilot has one
connector, perform planned rotation in a maintenance window: rotate the token
in Cloudflare, replace the service credential from an elevated private console,
restart the connector, confirm the dashboard reports the expected connector,
and repeat the non-secret service and public-origin probes below. Cloudflare
notes that an old token cannot create new connections after rotation, although
existing connections remain until restarted
([Cloudflare tunnel-token lifecycle](https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/)).

For suspected compromise, rotate first, force-disconnect the tunnel's existing
connections using the provider's documented dashboard/API recovery path,
replace the local service credential, and rerun the full qualification. For
host recovery, obtain a fresh token from Cloudflare and reinstall the service;
never restore a credential from source control, deployment evidence, chat, or
an operator's command history. Record only the approval, rotation timestamp,
non-secret tunnel name, and verification outcome in the operations log—never
the token, credential file, provider API credential, or service command line.

### Deploy

With the three tunnel routes already configured, deploy the exact clean
revision:

```powershell
$cloudflared = Get-Service cloudflared
if ($cloudflared.Status -ne "Running") {
  Start-Service cloudflared
}
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Deploy `
  -ExposureProfile cloudflare_trusted_edge `
  -AppHostname comms.avayaworks.com `
  -MediaHostname media.avayaworks.com `
  -ObjectHostname kcomms-files.avayaworks.com `
  -MediaNodeAddress 192.168.1.177 `
  -TrustedEdgeConfirmation cloudflare-tunnel-v1 `
  -AllowPublicNetworkProfile
if ($LASTEXITCODE -ne 0) {
  throw "K-Comms trusted-edge Deploy failed"
}
```

The CLI accepts reusable operator-supplied canonical hostnames and
receipt-sealed port overrides. This runbook qualifies only the exact three
`avayaworks.com` names above and `7981/TCP` plus `7982/UDP`. Different values
require a new clean deployment and the full automated and second-device gates;
they are not covered by this reference result.

The confirmation string records deliberate selection of the split topology; it
is not a secret. Windows currently reports this host's media interface as
**Public**, so the command includes the same explicit audited override as LAN
mode. That override is a risk acceptance, not a claim that the network is
trusted. It is valid only with separately administered firewall rules scoped
to the exact local address, trusted remote subnet, Public profile, `7981/TCP`,
and `7982/UDP`. Omit the override on a future host only when Windows reports
the exact intended interface as **Private**.

The release manager configures:

```text
PUBLIC_APP_URL=https://comms.avayaworks.com
LIVEKIT_SERVER_URL=wss://media.avayaworks.com
S3_PUBLIC_ENDPOINT=https://kcomms-files.avayaworks.com
```

It also seals the corresponding Phoenix host/origin, CORS, CSP, LiveKit node
address, two-listener media-forwarder contract, and loopback Podman
publications.

Schema v7 replaces the former gateway-derived proxy trust with one exact
application peer reservation. Its network record includes:

```text
trustedProxySourceKind=podman-app-self-v1
applicationNetworkName
applicationNetworkId
applicationNetworkSubnet
applicationNetworkGateway
applicationNetworkPrefixLength
applicationContainerIpv4
applicationContainerIpv4Cidr
trustedProxyCidr
```

`trustedProxyCidr` must equal `applicationContainerIpv4Cidr`, and both identify
only the reserved application IPv4 `/32`. The bridge gateway is recorded as
part of the complete network identity but is not trusted as a proxy source.
The manager creates the application stopped with
`compose up --no-start --no-deps`, verifies the Compose-owned app replica and
sealed image, validates its one unassigned bridge attachment and service
aliases, disconnects it, and reconnects it with the exact reserved IPv4 request
while preserving those aliases. Windows Podman reports an empty address and a
zero prefix while this container is stopped, so the manager verifies the exact
network name/ID and absence of a foreign active occupant at that stage.
`podman start` is the atomic allocator/collision authority. The manager starts
that already-created container without a Compose recreation and immediately
verifies the exact running network name, network ID, prefix, and address. An
occupied reservation or allocation race fails at start and triggers rollback;
an additional attachment, same-name/different-ID bridge, address drift,
ownership drift, image drift, or network specification drift also fails
closed. The manager never selects a replacement address.

The application accepts Cloudflare client/proto forwarding headers only from
that exact receipt-sealed application peer. It does not trust the bridge
gateway, an arbitrary forwarded header, or a broad private subnet. The
manager's public HTTPS probes require a browser-trusted edge certificate and
reachable routes, but they do not inspect Cloudflare Access, Cache Rules, DNS
ownership, certificate lifecycle, or provider availability settings. Manager
success alone is therefore not complete trusted-edge qualification.

### Start, stop, status, and rollback

Treat the immutable release and Cloudflare connector as two independent
lifecycle units. The manager does not change `cloudflared`, but its
trusted-edge actions intentionally probe the live public routes after local
health succeeds. Keep the connector running during `Deploy`, `Start`, and
`Rollback`:

```powershell
$cloudflared = Get-Service cloudflared
if ($cloudflared.Status -ne "Running") {
  Start-Service cloudflared
}
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Start
if ($LASTEXITCODE -ne 0) {
  throw "K-Comms trusted-edge Start failed"
}
```

`Stop` affects only the immutable local release and its media forwarder:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Stop
if ($LASTEXITCODE -ne 0) {
  throw "K-Comms Stop failed"
}
```

The automatic `cloudflared` connector remains running and the public routes
report an origin failure while K-Comms is stopped. Stop the connector
independently only for an approved tunnel incident or maintenance window;
doing so is not part of the release-manager lifecycle.

Inspect both units:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Status
Get-Service cloudflared
```

A healthy manager status must match the retained image, configuration,
`cloudflare_trusted_edge` profile, three hostnames, media-node address,
loopback Podman publications, and exact `7981/TCP` plus `7982/UDP` forwarder
listeners. `Get-Service` must report the independently managed tunnel service
as `Running`. Neither result substitutes for public HTTPS/WSS probes.

Rollback preserves the stable public names and requires the live tunnel for its
post-restore public probes:

```powershell
$cloudflared = Get-Service cloudflared
if ($cloudflared.Status -ne "Running") {
  Start-Service cloudflared
}
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Rollback
if ($LASTEXITCODE -ne 0) {
  throw "K-Comms trusted-edge Rollback failed"
}
```

The predecessor must carry a compatible retained trusted-edge profile and
media contract. After rollback, repeat all status, public-origin, anonymous
guest, and same-LAN media gates. If the independent tunnel is unavailable,
trusted-edge activation fails its public probes; restore the connector or use a
deliberate loopback recovery path without claiming trusted-edge health.

### Qualification

Install the committed web dependencies and Playwright Chromium as described in
the next section. Then run the sealed trusted-edge qualifier from the K-Comms
host while it is attached to the same LAN as the media node:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/qualify_local_release.ps1 `
  -BaseUri https://comms.avayaworks.com
```

The base URI must match the receipt exactly. A passing automated result must
prove the retained image/receipt and trusted-edge topology; HTTPS health,
packaged assets, strict CSP, exact
`Strict-Transport-Security: max-age=31536000; includeSubDomains`, CORS and
Origin behavior; real WSS LiveKit signaling; object readiness; anonymous
QR/link join and username roster; two-way text; real microphone and camera RTP;
screen sharing; device controls; access revocation; a real presigned attachment
upload and hash-verified download through the sealed public object hostname;
verified attachment/object cleanup; and clean teardown. It must not print
invitation, session, credential, signed-object, file-content, or tunnel-token
material.

Cloudflare Access and Cache Rule configuration are provider state outside the
sealed receipt. Check the three non-secret endpoints twice and emit only the
status, redirect target, and cache metadata:

```powershell
$targets = @(
  "https://comms.avayaworks.com/",
  "https://media.avayaworks.com/",
  "https://kcomms-files.avayaworks.com/minio/health/ready"
)
foreach ($target in $targets) {
  1..2 | ForEach-Object {
    curl.exe --silent --show-error --output NUL --max-redirs 0 `
      --write-out '%{http_code} redirect=%{redirect_url} cache=%header{cf-cache-status} age=%header{age}\n' `
      $target
    if ($LASTEXITCODE -ne 0) {
      throw "Trusted-edge probe failed for $target"
    }
  }
}
```

Also prove that the public application endpoint accepts TLS 1.2:

```powershell
curl.exe --silent --show-error --fail --output NUL `
  --tlsv1.2 --tls-max 1.2 `
  https://comms.avayaworks.com/health/ready
if ($LASTEXITCODE -ne 0) {
  throw "Trusted-edge TLS 1.2 probe failed"
}
```

Each probe must return its expected success status with an empty redirect
target. None of these dynamic/health endpoints may report `HIT`, `STALE`, or
`EXPIRED` on the second response, and `Age` must be absent or zero. A
Cloudflare Access login/challenge, external redirect, or cache hit on these
endpoints fails qualification. Inspect the dashboard rule scope as well: it
must show a hostname-scoped bypass for
`kcomms-files.avayaworks.com`, no catch-all bypass on the application or media
host, and no cache-everything rule covering their dynamic paths. Content-hashed
`/app/assets/` is intentionally outside this dynamic-response probe. Confirm
the dashboard still reports TLS 1.2 as the minimum; a legacy-protocol negative
probe is valid only from a test client that can itself negotiate that legacy
protocol. These public checks do not exercise a bearer invitation or signed
object URL, and those secrets must never be added to a diagnostic command.

Also perform a second-device same-LAN browser gate against
`https://comms.avayaworks.com`:

1. create a disposable room and open its QR/link in a second physical browser;
2. prove both usernames appear in both rosters;
3. exchange text in both directions;
4. grant microphone and camera only when prompted, then prove two-way audible
   audio and visible video;
5. start and stop screen sharing and verify the remote participant sees it;
6. switch or mute devices, leave the call, revoke/close the invitation, and
   verify cleanup; and
7. record browser/OS versions and pass/fail evidence without recording media,
   bearer URLs, credentials, or participant content.

Before calling the gate successful, verify that `4188/TCP`, `5900/TCP`, and
`7980/TCP` are not reachable on `192.168.1.177`, while `7981/TCP` and
`7982/UDP` are permitted only from the trusted LAN scope. UDP requires an
actual LiveKit/browser media test; a TCP listener probe cannot prove it.

### Exact limitations

- Trusted HTTPS/WSS enables the browser permission APIs but does not prove that
  WebRTC packets can reach LiveKit.
- Media is qualified only for clients on the same trusted LAN that can reach
  `192.168.1.177:7981/TCP` or `192.168.1.177:7982/UDP`.
- There is no remote/Internet media claim, TURN/UDP, TURN/TLS, NAT traversal,
  corporate-firewall traversal, Spectrum media path, or WARP dependency.
- Off-LAN media requires a separately deployed and qualified managed or
  Internet-reachable SFU/media plane; the Cloudflare control-plane routes do
  not make this host's RFC1918 ICE candidates remotely reachable.
- `media.avayaworks.com` carries API/signaling only. It is not an ICE media
  proxy.
- The three Cloudflare hostnames may be reachable from the Internet even though
  media is LAN-only. Do not distribute invitations outside the controlled
  pilot. If an approved source-network WAF policy restricts control-plane
  access, allowlist the pilot site's **public NAT egress IP/CIDR observed at
  Cloudflare**, not the RFC1918 media subnet. A dynamic WAN address can lock
  every pilot browser out when it changes, so pair that policy with an
  administered update/recovery procedure. The separate Windows Firewall rules
  still use the trusted LAN source subnet for direct ICE media.
- Cloudflare Tunnel, DNS, certificate, and Internet outages can break the
  browser control plane for devices on the same LAN.
- Same-LAN browsers still need working public DNS and outbound Internet access
  to reach the Cloudflare edge; only their ICE media packets stay on the LAN.
- Cloudflare can terminate WebSockets during edge changes; successful initial
  connection is not a no-disconnect guarantee.
- One `cloudflared` connector and one K-Comms host are not highly available.
- Cloudflare service status, edge policy, and DNS/certificate evidence are
  outside the immutable application receipt and must be checked separately.
- This profile does not satisfy managed-state, multi-zone recovery, capacity,
  privacy, independent security, accessibility-study, support/on-call, or
  production-approval gates.

The broader secure LiveKit target requires a trusted certificate plus
HTTPS/WSS termination, and restrictive networks normally require TURN
([LiveKit secure deployment](https://docs.livekit.io/transport/self-hosting/deployment/)).
Move to an approved managed/public SFU design and qualify its Internet ICE and
TURN/TLS paths before making any remote-media or production claim.

## One-command packaged browser and media qualification

After a default loopback `Deploy` or `Start` succeeds, qualify the sealed
release and its real media plane with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/qualify_local_release.ps1
```

The default qualifier targets `http://127.0.0.1:4188`. It first proves that the
running application image matches the retained immutable release receipt and
that the current exposure profile and address/interface/profile still match
that receipt. Loopback additionally requires `Forwarder: not-required`.
Clear-text LAN requires its current forwarder ready, identity-match, and
configuration-hash-match status lines shown above. The trusted-edge profile
requires the retained two-listener media forwarder and exact HTTPS/WSS origins;
public tunnel, DNS, and certificate behavior is proved by the later network
and browser probes rather than inferred from manager status. The supplied
`-BaseUri` is an expected origin only: it must equal the receipt's exact public
application origin. The qualifier reads the app, LiveKit signaling, and MinIO
API ports and public origins from `deployment.json` and builds its expected CSP
from those sealed values, including when non-default ports were deployed. It
then checks:

1. `/health/live` reports `ok`;
2. `/health/ready` reports ready database/runtime checks and configured object
   storage;
3. `/api/v1/status` reports an operational service with administration,
   realtime, audio-call, video-call, and guest-link capabilities available,
   plus `instant_rooms=true` and `bootstrap=false`;
4. `/app/` is packaged HTML that references built `/app/assets/` files rather
   than Vite/source assets; and
5. `/app/` returns the exact strict local-release Content Security Policy,
   including the sealed LiveKit and object-storage origins and no
   `unsafe-inline`, `unsafe-eval`, or wildcard source.

Before creating any disposable resource, the qualifier records a read-only,
content-free fingerprint of the fixed instant-room tenant graph through the
exact release image. Every supported qualification profile then writes a
schema-v3 cleanup marker and creates a random
`k-comms-qualification-<id>` tenant through the exact image's one-shot
qualification command. They also start a temporary, non-restarting instance of
the originating Compose `app` service from the marker-bound receipt, Compose
source, and environment. That application uses the exact image and revision,
the `edge` role, the disposable tenant slug, and a random
`127.0.0.1:<high-port>` publication. Its `PUBLIC_APP_URL` is that isolated
loopback origin, while the retained public origin remains a separate,
receipt-bound browser handoff target. The qualifier verifies the temporary
container's deterministic name, ownership labels, image, revision,
environment, hardening, loopback-only listener, readiness, and runtime role
before the browser gate begins.

`e2e/live-instant-room.spec.ts` opens the temporary origin first and creates the
host's room there. Only this temporary browser context sends the
qualification-id-derived documentation IPv6 address in `X-Forwarded-For`; the
temporary application accepts it only when the connection source is the exact
originating application network gateway `/32`. The test also proves that room
creation uses the temporary origin as both its request origin and natural
`Origin` header. It keeps the complete serialized guest session in memory,
closes that browser context, and installs the session into a new
public-origin context before the retained public page boots. The guest then
opens the exact public share URL. Host and guest send no forwarded-address
header through the public path and prove username-based roster presence plus
two-way text through the retained application and, in clear-text LAN mode, its
retained forwarder. Trusted-edge browser control traffic instead traverses the
independently administered Cloudflare route. Playwright traces, screenshots,
video, and AI failure-copy are disabled for this bearer-bearing journey, and
the captured share field is redacted before later assertions.

That gateway rule is isolated to this disposable qualification application and
its documentation-only forwarded address. It does not describe or weaken the
retained schema-v7 application's `podman-app-self-v1` peer reservation.

The instant-room journey remains anonymous-only and never converts either
browser identity. Default loopback and trusted-edge qualification then run
`e2e/live-guest-communication.spec.ts`, `e2e/live-audio.spec.ts`, and
`e2e/live-video.spec.ts`, in that order, against the same disposable tenant
with one Playwright worker. Optional account conversion remains isolated in
the live guest specification; that specification verifies the converted
identity remains in the disposable tenant. The media tests prove real
microphone RTP, camera RTP, group calls, screen sharing, access revocation,
and clean call teardown.

Trusted-edge qualification additionally creates one unclaimed text attachment
inside the same disposable tenant. It signs in only through the isolated
qualification application, creates and completes the attachment through
`https://comms.avayaworks.com`, sends the exact signed `PUT` headers to the
receipt-sealed `https://kcomms-files.avayaworks.com` origin, and first verifies
the browser-equivalent CORS preflight plus exact application-origin response
header. It waits at most 60 seconds for the configured scanner to mark the
object clean and downloads it through that same public object origin. The gate
requires an exact byte count and SHA-256 match. Redirects, another object
hostname, insecure transport, a missing CORS grant, unexpected signed headers,
an oversized response, scan failure, or timeout fails qualification.

Cleanup is mandatory even when a transfer step fails. The qualifier abandons
the unclaimed attachment through its authenticated API, runs the originating
exact image's tenant-bound object-version purge against the internal storage
path, and requires the still-valid public signed download to return `404`
before the disposable tenant is removed. It also revokes the temporary owner
session. Signed URLs, bearer tokens, credentials, and file bytes remain
in-memory only; failure output contains only the named phase and status, never
those values. Do not enable PowerShell HTTP debugging or transcript capture
around this gate.

Plain-HTTP LAN text-only qualification stops after the anonymous instant-room
roster/text journey and also proves that sign-in is rejected with HTTP 426
`secure_transport_required`. It does not read or propagate the sealed owner
credentials and does not attempt sign-in, account conversion,
account-authenticated guest links, audio, or video.

The rejection applies to every HTTP request handled by a LAN-configured
release, including requests addressed to its loopback listener. The raw TCP
forwarder cannot securely distinguish a genuine loopback client from a LAN
client that supplied a loopback `Host` value. Run a separately deployed
loopback profile for operator credential workflows, or provide trusted
HTTPS/WSS.

Install the committed web dependencies and Playwright Chromium before running
the qualifier:

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
capabilities, packaged assets, CSP, instant-room endpoint, the server-side
secure-transport boundary, and the anonymous live instant-room text flow. It
intentionally skips credential, conversion, account-authenticated guest-link,
audio, and video specifications. Its final output states that credential and
media operations were **not qualified**. A default loopback qualification
cannot opt out of media and continues to require both real audio and video
gates. In short, media was **not qualified** by the LAN text-only result.

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
loopback qualifier separately runs `e2e/live-guest-communication.spec.ts`
against the exact packaged runtime. Its first case uses the isolated
qualification owner through the loopback-only internal application port, then
uses the owner browser UI to create a communication-only link and QR code,
proves the QR
contains the exact displayed link, opens that link in a clean browser, proves
the fragment secret is scrubbed, joins with only a display name, delivers a
realtime message, and verifies revocation ends both API and socket access.
The random qualification password remains process-only and is not printed. A
second isolated live case creates and redeems the preauthorized single-use
fixture, proves a
mismatched conversion email fails closed, converts the same user in place with
the exact email, proves the converted session remains in the exact
`k-comms-qualification-<id>` tenant, reaches `/api/v1/me` as a human, and
denies the old guest credential. The guest specification rejects any owner
slug outside that marker-bound disposable namespace. This
account-authenticated suite is not run by `-LanTextOnly`.
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
- when a candidate receipt was written but never published, the renamed
  `unpublished-deployment.json` plus its exact path and SHA-256 sealed in the
  paired `failure.json`; the active receipt name `deployment.json` is never
  retained for that failed candidate;
- for LAN mode, the retained forwarder script, its exact JSON configuration,
  SHA-256 hashes, atomic ready record, and stdout/stderr logs;
- for trusted-edge mode, the three public hostnames, loopback origins,
  media-node address, explicit non-secret confirmation, and retained
  two-listener media-forwarder evidence—but no Cloudflare token, account/zone
  identifier, credential-bearing tunnel configuration, or provider secret; and
- migration/failure/rollback receipts.

Do not copy the unredacted environment or rendered configuration into the
repository, tickets, chat, or CI artifacts. The script rejects a state path
inside the repository.

Every qualification profile derives the random qualification id, application
nonce, documentation client address, and any required password in process
memory. Passwords and bearer sessions are never written to the cleanup marker
or printed. The permanent bootstrap owner and fixed instant-room tenant are
never used for disposable fixtures. Qualification is serialized by a named
mutex plus the release state root's `operation.lock`; after acquiring both, the
qualifier revalidates the active receipt, image, and topology before creating
fixtures and again before reporting success.

Before either the disposable tenant or temporary application is created, the
qualifier writes one secret-free schema-v3
`qualification-cleanup.json` marker at the state root shared by every retained
candidate. In addition to the random tenant id, it binds the temporary
application's deterministic name, nonce, random loopback port and origin,
qualification-only trusted gateway `/32`, documentation client address, and
retained public origin to the originating deployment receipt, environment,
Compose source, project, Git revision, and image ID. It uses only paths, hashes,
addresses, and public image metadata.

The mandatory `finally` recovery path verifies and removes the temporary
application by its inspected container ID, confirms that it is absent, deletes
the exact disposable tenant through the originating one-shot boundary, and
only then deletes the marker. A same-name container whose image, revision,
labels, environment, publication, or hardening differs from the marker is
treated as a decoy: removal and tenant deletion both fail closed, leaving the
marker for investigation. The next qualifier run performs the same stale
recovery before starting new work. It accepts a legacy schema-v2 marker only
for its original tenant-only recovery path; schema v3 is required for new
work. Recovery remains possible after the active candidate changes—even when
the new candidate lacks the qualification service—and fails closed if an
origin asset was removed or tampered with.

After the cleanup path, the qualifier reads the fixed instant-room tenant
fingerprint again through the exact release image and requires an exact match.
That second read runs even when a browser, media, or cleanup gate failed, and
its failure is reported independently. The fingerprint contains only a
tenant-presence flag, table counts, and a SHA-256 identity digest, never row
ids, slugs, message content, credentials, or bearer material.

### Missing current pointer after a failed first candidate

The absence of `current.json` normally means there is no release to adopt.
`Deploy` fails closed when it finds a stable environment, history, project
containers, or owned data volumes without that pointer. Do not delete the
retained evidence, invent a pointer, or treat an arbitrary state directory as a
fresh install.

One narrow retry exists for a manager-proven failure of the first-ever
candidate. Correct and commit the candidate, reuse the exact state root and
Compose project, specify the complete intended topology again, and append this
exact acknowledgement to the new `Deploy`:

```powershell
-FailedFirstCandidateRetryConfirmation failed-first-candidate-retry-v1
```

The token is intent, not an adoption or cleanup bypass. The manager accepts it
only when all of the following are true:

- `current.json` is absent, no active-named `deployment.json` exists anywhere
  below the history root, and no container exists for the Compose project;
- the latest retained `failure.json` is a regular, non-reparse file under its
  exact candidate directory, and its candidate id and project match that
  directory and the requested project;
- `previousReceiptPath` is empty and
  `schema6CutoverIrreversible` is false, proving this is a failed first
  candidate rather than a lost current pointer, failed upgrade, or irreversible
  schema-v6 cutover;
- the stable environment's presence and SHA-256 match the failure record;
- every retained candidate environment, Compose source, and source archive
  named by the failure record is a regular file inside the same candidate
  directory and matches its recorded SHA-256; and
- a runtime-touched failure has complete environment and Compose evidence.

Named PostgreSQL and MinIO volumes may remain because preserving them is the
purpose of this recovery, but they do not weaken any identity or hash check.
Any project container or successful active-named receipt blocks the retry.
When an exact healthy receipt exists but `current.json` was lost, restore that
exact pointer through an approved recovery procedure instead of using this
token.

A late failure can occur after the candidate's receipt was written but before
its `current.json` publication completed. Only after supervisor, forwarder, and
runtime cleanup succeeds does the manager hash that uncommitted receipt,
atomically write `failure.json` with the intended
`unpublishedDeploymentReceiptPath` and
`unpublishedDeploymentReceiptSha256`, and then atomically rename
`deployment.json` to `unpublished-deployment.json`. An interruption before the
rename leaves the active receipt name in place, so retry fails closed. On retry,
the optional archived file is accepted only at the sealed co-located path, with
the exact hash and candidate/project identity recorded by the failure. It
remains failure evidence, never a healthy or activatable release. A remaining
`deployment.json`, an unpaired unpublished file, a path outside the candidate
directory, or any identity/hash mismatch fails closed.

The retry creates and qualifies a new immutable candidate. It never publishes
or starts the failed candidate and never mutates the retained evidence to make
it appear successful. If the retry also fails, preserve the new failure record
and investigate before another explicitly acknowledged attempt.

## Status, start, stop, and rollback

```powershell
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action HealthCheck
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Start
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Stop
powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Rollback
```

`Stop` stops the exact receipt-matching LAN or trusted-edge media forwarder
before the Compose runtime, then retains images, receipts, PostgreSQL data,
MinIO data, forwarder evidence, and configuration. It never kills an unrelated
Node process. It does not stop the independently administered `cloudflared`
service.

`Start` verifies the recorded environment, Compose, rendered configuration,
source-archive hashes, image revision label, image ID, image digest, and any
required forwarder script/configuration hashes. It then starts only the
currently recorded immutable release from its retained Compose and
environment, reruns the same forward-only migration command (normally a no-op
for an already-current database), recreates the packaged application, and
repeats loopback health checks. For LAN mode it safely replaces the managed
forwarder, verifies its current ready identity/hash/listeners, and only then
probes the public address. It does not require a clean checkout, read the
checkout Compose file, or rebuild an image. For trusted-edge mode it safely
replaces and verifies only the two-listener media forwarder; it does not start
or validate the independent Cloudflare connector.

`Start` accepts schema-v3 and schema-v4 receipts only for loopback
compatibility. Existing schema-v5 receipts remain valid for status, start, and
rollback. Schema-v6 receipts introduced the explicit exposure profile and
sealed public-origin record while retaining the audited network profile,
loopback Podman bind, exposure mode, and forwarder record. A schema-v6
trusted-edge receipt derived trust from the Podman gateway and therefore is
not safe to activate under the corrected peer model; `Start` and `Rollback`
reject it and require a clean schema-v7 redeployment rather than reinterpret
its old `trustedProxyCidr`. A v6 trusted-edge release has exactly one supported
upgrade: an explicitly acknowledged, irreversible clean cutover under the
**same** `-StateRoot` and `-ProjectName`. Do not select a new project: doing so
would create new secrets and empty PostgreSQL/MinIO volumes.

Before cutting over, create and restore-test an approved backup. If that is not
available, the operator must deliberately accept the data/migration risk
encoded by the exact confirmation token. Then use the same state and project:

```powershell
$stateRoot = Join-Path $env:LOCALAPPDATA "K-Comms\local-release"
$projectName = "k-comms-release"

powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Stop `
  -StateRoot $stateRoot `
  -ProjectName $projectName
if ($LASTEXITCODE -ne 0) {
  throw "Schema-v6 trusted-edge Stop/quiescence failed"
}

powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 `
  -Action Deploy `
  -StateRoot $stateRoot `
  -ProjectName $projectName `
  -ExposureProfile cloudflare_trusted_edge `
  -AppHostname comms.avayaworks.com `
  -MediaHostname media.avayaworks.com `
  -ObjectHostname kcomms-files.avayaworks.com `
  -MediaNodeAddress 192.168.1.177 `
  -TrustedEdgeConfirmation cloudflare-tunnel-v1 `
  -Schema6CutoverConfirmation `
    schema6-irrevocable-cutover-data-risk-v1 `
  -AllowPublicNetworkProfile
if ($LASTEXITCODE -ne 0) {
  throw "Schema-v6 to schema-v7 trusted-edge cutover failed"
}
```

`Stop` is the sole non-upgrade schema-v6 trusted-edge lifecycle escape hatch.
It verifies retained environment, Compose, rendered configuration, source, and
forwarder hashes plus exact Compose project/app/image ownership. After stopping
the services it proves that no project container or exact-command media
forwarder remains running, no media listener or supervisor task remains, the
stable environment matches the retained release without needing normalization,
and both Compose-owned data volumes have no running or foreign mount user.

`Stop` is also idempotent after an irreversible schema-v6-to-v7 candidate has
failed. The manager removes the candidate runtime, then uses the exact retained
v6 environment, Compose source, image, and project to recreate only the old
application with `--no-start`. It verifies that stopped container as the
non-activating audit anchor, re-proves the full quiescence contract, and only
then seals the candidate failure evidence. The v6 `current.json` remains the
cutover audit pointer; the anchor is not an activatable rollback.

A repeated `Stop` validates the exact current v6 receipt and retained assets,
requires that audit anchor to have the recorded Compose project/app/image
identity, stops it idempotently, and re-proves that the project has no running
container, forwarder/listener/supervisor, or running/foreign retained-volume
user. It returns success without starting anything or rewriting the pointer.
A missing or mismatched anchor fails closed. This path uses no
`failed-first-candidate-retry-v1` token; a corrected cutover repeats the stopped
`Deploy` with `schema6-irrevocable-cutover-data-risk-v1`.

`Deploy` repeats that proof before creating the candidate. The candidate reuses
the exact stable environment and data volumes, but its database migration has
no automatic v6 rollback. A successful v7 receipt sets `previousReceiptPath` to
null and records the v6 source only in `schema6CutoverFromReceiptPath`. On
failure, the manager removes candidate containers without deleting volumes or
stable secrets, restores and verifies only the stopped v6 audit anchor, keeps
the v6 current pointer as audit/retry evidence, and never reactivates the
obsolete gateway-trust release. Correct the failure and repeat the same stopped,
explicitly confirmed cutover; `Deploy` re-proves the anchor before candidate
mutation. Never use `Start` on v6.

Every new deployment writes schema v7. Trusted-edge schema-v7 receipts require
the three public origins, `trustedProxySourceKind=podman-app-self-v1`, the exact
bridge name, immutable network ID, subnet, gateway, prefix, reserved
application IPv4 and matching `/32` CIDR, media-node address, exact
confirmation, and media-only forwarder profile. `Start` and `Rollback` inspect
and reuse that exact reservation; they never select a replacement address or
rewrite the receipt when the reservation is occupied or topology has drifted.
They create the app stopped, restore its sealed attachment, verify
ownership/image/network/aliases, and submit the same sealed address request.
Because Windows Podman leaves a stopped attachment unassigned, container start
is the atomic collision gate; the exact running prefix/address is verified
immediately afterward without recreation. Any mismatch fails closed before the
receipt becomes active. Older non-trusted-edge receipts remain restartable only
under their own compatible sealed profile. The manager rejects receipt schema
versions newer than v7 instead of interpreting them with stale lifecycle
logic.
Before activating a receipt that lacks guest rollback capabilities, `Start`
runs the same quiesced PostgreSQL hazard probe. This fails closed when a
migrated failed candidate left guest rows or jobs while `current.json` still
names its legacy predecessor; use a guest-compatible bridge or roll-forward
recovery instead.

`Status` reports both the recorded receipt and the observed application
container state, health, image ID, and image-match result. It also reports
`Forwarder: not-required` for loopback or, for clear-text LAN and trusted-edge
media, the current forwarder readiness plus receipt-identity and
configuration-hash matches. A recorded receipt is not presented as current
runtime health when the container is stopped, unhealthy, unavailable, running
another image, or paired with a stale or mismatched forwarder. The command does
not report Cloudflare service, DNS, edge-certificate, or route health. `Status`
and the compact `HealthCheck` action both return nonzero when the sealed
topology, exact image, application health, forwarder, or required supervisor is
not ready; use `HealthCheck` for external monitoring.

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

`K_COMMS_LOCAL_RELEASE=true` is a deliberately narrow exception for the
loopback, exact private-LAN, or exact Cloudflare trusted-edge topology. The
runtime also requires `ALLOW_DEVELOPMENT_ADAPTERS=true`, the selected exact
public HTTP/WS or HTTPS/WSS origins, and the internal API origin
`http://livekit:7880`. Compose additionally requires
`K_COMMS_PODMAN_BIND_ADDRESS=127.0.0.1`; the selected public host or media node
is never substituted into a Podman `ports` entry. A clear-text LAN selection
additionally requires the exact guarded local-release host and its five
listener forwarder. A trusted-edge selection requires the three exact
`avayaworks.com` hostnames, exact guarded media node, explicit confirmation, and
only the `7981/TCP` plus `7982/UDP` forwarder contract. Both LAN-address modes
require a matching observed Windows interface/profile receipt and either a
Private profile or the explicit audited non-Private-profile override. Missing,
public-IP, unassigned, wildcard, directly published RFC1918, stale forwarder,
or broader combinations fail closed.

The trusted-edge profile also requires the schema-v7 app-self bridge contract
above. Direct `http://127.0.0.1:4188` access remains a
local-operator-trust-only boundary: it is not a shareable trusted-edge origin
and must never be used to assert forwarded client identity. Protected
trusted-edge operations require the public HTTPS origin. Use a separately
deployed loopback profile for any explicitly supported local operator workflow
that cannot use the trusted edge.

This proves local packaging, migration, dependency startup, application
readiness, immutable restart, and application rollback. Signaling checks alone
do not prove successful WebRTC packets. Browser media tests are therefore
required before calling the release media-capable. A `-LanTextOnly` result is
deliberately not media qualification; it also does not qualify sign-in,
account conversion, or account-authenticated guest links. Use the full loopback
qualifier or the trusted HTTPS/WSS qualification plus its second-device LAN
gate before making credential or media claims.

On Podman Desktop, LiveKit's published TCP and UDP ports remain on
`127.0.0.1` while `--node-ip` advertises the selected loopback or RFC1918 media
host. In clear-text LAN mode the managed host forwarder owns all five
selected-address listeners. In trusted-edge mode it owns only the selected
address's `7981/TCP` and `7982/UDP` media listeners; Cloudflare independently
connects the three browser-facing origins to loopback. Do not enable LiveKit's
separate `rtc.enable_loopback_candidate` option: real-browser qualification
showed that it prevents the mapped TCP candidate from being selected. The
release policy validator rejects that flag.

For a trusted-edge receipt, the release manager also registers a
current-user, limited-privilege Windows Scheduled Task whose action is bound to
the exact receipt path, candidate id, forwarder configuration hash, manager
script hash, state root, and Compose project. The task executes a hash-sealed
manager copy taken from the immutable Git snapshot and retained beside the
deployment receipt, using the exact existing PowerShell engine that created the
receipt. Later source-checkout edits cannot disable or alter active-release
recovery. Health requires the task to remain enabled, `Ready` or `Running`, and
configured with its exact receipt-sealed start boundary, one-minute trigger,
active repetition window, principal, action, restart policy, and execution
limit. Task Scheduler must also report a non-missing next run within the
one-minute interval plus the sealed two-minute scheduling grace; a future-dated,
expired, missing, or stale schedule fails health. It checks once per minute and
safely replaces an unexpectedly exited media-only forwarder only while the exact
retained application remains healthy. It can expose only the receipt's
`7981/TCP` and `7982/UDP` listeners. `Deploy`, `Start`, and `Rollback` register
the task before publishing the newly active `current.json`; `Stop` and release
replacement stop and unregister it before terminating the forwarder,
preventing an intentional stop from being undone. A same-name task with a
mismatched action, principal, or ownership description is never overwritten
or removed. The loopback and clear-text LAN profiles retain their existing
lifecycle behavior and do not register this trusted-edge supervisor.

For the loopback and clear-text LAN profiles, external HTTPS/WSS remains
outside qualification. The Cloudflare profile qualifies only its three exact
HTTPS/WSS origins and same-LAN direct ICE path. Remote media, TURN/TLS, managed
state, multi-zone resilience, provider approval, signed publication
attestations, security approval, accessibility studies, and on-call readiness
remain outside every local-release qualification.
