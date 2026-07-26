# ADR-0054: Use a Cloudflare trusted edge for same-LAN browser media

- **Status:** Accepted for controlled same-LAN qualification; not production
- **Date:** 2026-07-25
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0025, ADR-0047, ADR-0050, ADR-0051, ADR-0053

## Context

The explicit private-LAN profile in ADR-0051 deliberately exposes
`http://<RFC1918-address>` and `ws://<RFC1918-address>`. That profile is useful
for anonymous roster and text qualification, but a non-loopback HTTP origin is
not a browser-trusted secure context. Microphone, camera, and screen-capture
APIs therefore cannot be qualified there. It also sends application, session,
guest-link, and object traffic across the LAN without TLS.

The server and intended pilot devices share one trusted LAN. The
`avayaworks.com` zone is managed in Cloudflare, so Cloudflare Tunnel can provide
publicly trusted HTTPS/WSS browser origins while forwarding HTTP traffic to
loopback services on the K-Comms host. Cloudflare documents that a published
application maps a public hostname to a local service, and that several
hostnames can share one tunnel
([Cloudflare Tunnel routing](https://developers.cloudflare.com/tunnel/routing/)).

That HTTP edge does not solve the WebRTC media path. Cloudflare's standard
published-application routes proxy HTTP/HTTPS; non-HTTP services require
client-side `cloudflared`, and Cloudflare describes TCP/UDP publication
separately through Spectrum and virtual networks. LiveKit, independently,
requires direct ICE media ports and advertises them as WebRTC candidates
([Cloudflare supported protocols](https://developers.cloudflare.com/tunnel/routing/#supported-protocols),
[LiveKit ports and firewall](https://docs.livekit.io/transport/self-hosting/ports-firewall/)).
The controlled pilot therefore needs a split edge: Cloudflare for HTTPS/WSS
control and object traffic, plus LAN-only direct ICE media.

## Decision

Add an explicit `cloudflare_trusted_edge` local-release exposure profile. The
selected `avayaworks.com` reference deployment uses the following fixed
browser-facing names:

| Purpose | Public origin | Loopback tunnel origin |
|---|---|---|
| K-Comms UI, API, and Phoenix socket | `https://comms.avayaworks.com` | `http://127.0.0.1:4188` |
| LiveKit API and signaling | `wss://media.avayaworks.com` | `http://127.0.0.1:7980` |
| Browser object upload/download | `https://kcomms-files.avayaworks.com` | `http://127.0.0.1:5900` |

The manager interface remains reusable: it validates operator-supplied,
distinct canonical DNS names and receipt-sealed ports rather than hard-coding
this zone. The names and `7981`/`7982` ports below are the exact selected and
qualified values for this reference deployment. A deployment with different
names or ports is a different receipt-sealed topology and must pass its own
clean deployment and full qualification before it inherits any claim.

The following constraints are part of the decision:

1. Invoke the reference deployment with the following explicit, exact input:

   ```powershell
   -ExposureProfile cloudflare_trusted_edge `
   -AppHostname comms.avayaworks.com `
   -MediaHostname media.avayaworks.com `
   -ObjectHostname kcomms-files.avayaworks.com `
   -MediaNodeAddress 192.168.1.177 `
   -TrustedEdgeConfirmation cloudflare-tunnel-v1 `
   -AllowPublicNetworkProfile
   ```

   The manager validates distinct canonical DNS names rather than hard-coding a
   tenant's zone, then seals the exact selected values in the receipt. The
   confirmation is deliberate operator intent, not a credential. The
   current host's Windows adapter is classified **Public**, so the separate
   profile override is an explicit risk acceptance; it does not make that
   network trusted or create firewall rules.
2. Podman publications for the application, LiveKit signaling, and object API
   remain on `127.0.0.1`. The Cloudflare routes terminate public TLS and connect
   only to those loopback origins. PostgreSQL and the MinIO console are never
   tunnel routes. Cloudflare supports proxied WebSockets but may terminate them
   during edge-code releases, so Phoenix and LiveKit clients retain their
   reconnect behavior
   ([Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)).
3. The application receives the exact public origins:
   `PUBLIC_APP_URL=https://comms.avayaworks.com`,
   `LIVEKIT_SERVER_URL=wss://media.avayaworks.com`, and
   `S3_PUBLIC_ENDPOINT=https://kcomms-files.avayaworks.com`. Phoenix host/origin
   validation, CORS, and CSP must admit only the corresponding HTTPS/WSS
   origins, in addition to required internal service addresses. Forwarded
   client/proto headers are trusted only from the exact observed
   application-network gateway `/32` sealed in the release receipt, never from
   an arbitrary loopback/private subnet or untrusted request.
4. Cloudflare Tunnel is an independently administered Windows service. Use a
   K-Comms-dedicated tunnel/connector and keep it running while the release
   manager performs `Deploy`, `Start`, or `Rollback`, because those actions
   include public-origin probes. The release manager records and verifies its
   own trusted-edge topology but does not create the tunnel, change DNS,
   install `cloudflared`, store a tunnel token, or claim that the service is
   healthy.
   Cloudflare recommends running `cloudflared` as a service for availability
   ([Cloudflare service guidance](https://developers.cloudflare.com/tunnel/advanced/local-management/as-a-service/)).
5. Tunnel credentials, token files, account/zone identifiers, and any generated
   configuration containing credentials stay outside the repository and
   outside deployment receipts. The reference Windows service must use
   `--token-file` with an ACL-protected file outside the checkout; an inline
   `--token` service definition is not accepted. Never place the token in a
   reusable command, script, log, Git file, or receipt. The Cloudflare zone
   administrator owns routine rotation, immediate compromise revocation, and
   host recovery, with only non-secret outcomes recorded
   ([Cloudflare tunnel run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/#token-file),
   [Cloudflare tunnel-token lifecycle](https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/)).
6. Do not place a Cloudflare Access authentication challenge in front of the
   anonymous instant-room path, its required API calls, Phoenix WebSocket,
   LiveKit signaling, or signed object requests. A host-level Access login
   would add a second identity boundary and prevent a guest from opening a
   bearer invitation directly; the browser SDKs also cannot complete an
   interactive Access challenge in those supporting requests. If account-wide
   “Require Access protection” is enabled, explicitly exempt all three
   hostnames from that default-deny setting. K-Comms application authorization,
   expiring guest links, rate limits, WAF controls, and audit records remain
   authoritative. Future Access protection belongs on a separate admin-only
   hostname, not on this anonymous guest surface. Cloudflare cautions that an
   Access Bypass policy disables Access controls and Access request logging for
   matching traffic
   ([Cloudflare Access bypass guidance](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/common-policies/#bypass-a-public-endpoint)).
7. Apply a hostname-scoped **Bypass cache** rule to
   `kcomms-files.avayaworks.com`, including its health and signed object
   requests. Keep Cloudflare's normal dynamic-content behavior on
   `comms.avayaworks.com` and `media.avayaworks.com`: do not add a
   cache-everything rule for HTML, API/session, bearer invitation, Phoenix
   socket, or LiveKit signaling traffic. Content-hashed `/app/assets/` may use
   normal cache behavior without caching the surrounding authenticated or
   guest flow. Cloudflare likewise recommends keeping login and application API
   responses out of cache
   ([Cloudflare dynamic-content guidance](https://developers.cloudflare.com/cache/troubleshooting/dynamic-content-and-login-issues/)).
   The `avayaworks.com` zone is dedicated solely to K-Comms, so enable
   zone-wide **Always Use HTTPS**; Cloudflare documents that this redirects
   visitor HTTP requests for every host and subdomain
   ([Cloudflare Always Use HTTPS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/always-use-https/)).
   Enabling it requires a DNS/application inventory proving the zone remains
   K-Comms-only; otherwise use hostname-scoped redirect rules. Set the zone's
   **Minimum TLS Version** to **TLS 1.2**
   ([Cloudflare minimum TLS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/minimum-tls/)).
   Set the zone's
   **WebSockets** control to **On** and keep **Argo Smart Routing** disabled,
   because Cloudflare documents Argo as incompatible with WebSockets
   ([Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)).
8. Keep every tenant's `max_attachment_bytes` no greater than the effective
   Cloudflare zone upload ceiling. The reference tenant's 25 MiB default is
   below Cloudflare's current lowest documented plan ceiling, but the zone
   setting can reduce that value; a higher K-Comms limit is not qualified until
   both limits agree
   ([Cloudflare 413 guidance](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/)).
9. `media.avayaworks.com` is signaling only. WebRTC media bypasses Cloudflare
   and uses direct, same-LAN ICE candidates on exactly
   `192.168.1.177:7981/TCP` and `192.168.1.177:7982/UDP`. The host forwarder and
   Windows Firewall expose only those two ports on the exact LAN interface and
   trusted remote subnet. Ports `4188`, `5900`, and `7980` remain loopback-only.
   LiveKit documents `rtc.tcp_port` as the ICE/TCP fallback and `rtc.udp_port`
   as the optional single-port UDP mux
   ([LiveKit ports and firewall](https://docs.livekit.io/transport/self-hosting/ports-firewall/)).
10. The profile may be called media-capable only after a second physical browser
   on the same LAN proves microphone, camera, screen sharing, participant
   visibility, two-way audio/video, device controls, and cleanup over the exact
   sealed release. A secure origin alone is not media evidence.
11. `Start`, `Status`, `Stop`, and `Rollback` remain receipt-driven. They verify
    or reuse the retained exposure profile, three exact hostnames, loopback
    origins, media node address, two-listener LAN contract, image identity, and
    configuration hashes. They do not mutate Cloudflare state. Rollback keeps
    the stable public names and may activate only a predecessor whose retained
    receipt declares compatible trusted-edge and media configuration.
12. A limited-privilege Windows Scheduled Task supervises only the trusted-edge
    media-only forwarder. Its action is bound to the exact active receipt path,
    candidate id, forwarder configuration hash, manager-script hash, state
    root, and Compose project. It checks once per minute and restarts the exact
    two-listener process only while the sealed application image is healthy.
    Lifecycle operations unregister it before intentional stop or replacement
    and register it only for the newly active receipt. The task never owns the
    application, signaling, object, PostgreSQL, or MinIO-console listeners.

## Scope boundary

This profile establishes a trusted browser origin and a same-LAN media path. It
does **not** establish:

- remote or Internet WebRTC media;
- TURN/UDP, TURN/TLS, NAT traversal, or corporate-firewall traversal;
- Cloudflare Spectrum, WARP, or client-side `cloudflared` media carriage;
- origin or tunnel high availability;
- managed production state, multi-zone recovery, production capacity, privacy
  approval, security approval, support/on-call readiness, or a production SLA;
- protection of an anonymous public hostname by Cloudflare Access; or
- that a browser permission grant implies successful media transport.

LiveKit requires a trusted certificate and WSS endpoint for secure deployment
and recommends TURN for restrictive networks
([LiveKit deployment guidance](https://docs.livekit.io/transport/self-hosting/deployment/)).
Off-LAN media requires a separately deployed and qualified managed or
Internet-reachable SFU/media plane; the Cloudflare control-plane routes do not
make the host's RFC1918 ICE candidates remotely reachable. Those
remote-connectivity requirements remain a separate promotion gate.

Because the three DNS names are public Cloudflare hostnames, Internet users may
reach the HTTP/WSS control plane unless a separately approved Cloudflare
firewall policy limits source networks. The application must therefore remain
hardened as an externally reachable service even though qualified media is
LAN-only. Do not distribute invitations outside the controlled pilot.

## Consequences

### Positive

- Browsers receive publicly trusted HTTPS/WSS origins without private
  certificate installation on every pilot device.
- Application, signaling, and object origins remain explicit and independently
  constrained.
- Podman's application and stateful service publications remain loopback-only.
- Only the two required LiveKit ICE media ports are exposed to the trusted LAN.
- Existing anonymous QR/link onboarding remains a one-step guest journey.
- Stable hostnames survive a host IP change on the browser control plane; the
  media node address remains intentionally receipt-pinned and must be
  redeployed when it changes.

### Negative

- The profile depends on Cloudflare DNS, certificate issuance, tunnel service,
  and the host's Internet connection even for two devices on the same LAN.
- Pilot browsers need public DNS and outbound Internet access for the
  Cloudflare control plane even though their ICE media remains on the LAN.
- The control plane can remain externally reachable while media is LAN-only,
  which can confuse operators unless the limitation is displayed and tested.
- Media fails when the client is not on the LAN, UDP/TCP firewall rules are
  wrong, the DHCP address changes, or the Windows-to-Podman forwarding path is
  unavailable.
- Cloudflare and release lifecycle evidence are separate; both must be checked
  during start, incident response, and qualification.
- The tunnel token needs an independently owned rotation, revocation, and host
  recovery process; no credential lifecycle evidence belongs in a release
  receipt.
- One tunnel service and one host are not highly available.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Continue with `http://<LAN-IP>` | It is not a trusted browser origin and leaves browser/control traffic clear text. |
| Tunnel LiveKit ICE TCP/UDP through standard public-hostname routes | Standard HTTP tunnel routes do not provide the browser's direct WebRTC UDP/TCP candidate path. |
| Put Cloudflare Access in front of all K-Comms routes | Adds a second login and blocks the intended anonymous QR/link guest journey. |
| Expose application, object, and signaling ports directly on the LAN | Unnecessarily expands clear-text listener scope and bypasses the trusted edge. |
| Claim remote media after HTTPS/WSS signaling succeeds | Signaling is not evidence that ICE media or TURN traversal works. |
| Commit tunnel token/configuration to simplify startup | Creates a durable credential leak and couples provider secrets to source history. |
| Use a private CA or self-signed certificate | Requires device trust distribution and does not match the selected Cloudflare-managed public hostname path. |

## Validation

- Release static validation requires the explicit trusted-edge profile,
  distinct canonical hostnames, a canonical locally assigned RFC1918 media
  node address, the two media-listener ports, and confirmation value; the
  receipt then seals the exact selected `avayaworks.com` values.
- The retained receipt and status output prove loopback-only Podman
  publications, exact HTTPS/WSS origins, the selected media node address,
  two-listener LAN forwarding, and immutable image/configuration identity.
- Public probes verify:
  - `https://comms.avayaworks.com/health/ready`;
  - `https://comms.avayaworks.com/app/`;
  - `wss://media.avayaworks.com`; and
  - `https://kcomms-files.avayaworks.com/minio/health/ready`.
- Response inspection proves a valid public certificate, expected
  `Strict-Transport-Security`, CSP/CORS/Origin behavior, no cache hit for
  dynamic or signed flows, and no Cloudflare Access redirect/challenge on the
  anonymous guest journey.
- A host and second same-LAN physical browser prove QR/link join, username
  roster, two-way text, microphone, camera, screen sharing, participant/device
  controls, and room cleanup.
- Negative tests prove that `4188`, `5900`, and `7980` are not LAN listeners,
  and that a non-LAN client is not reported as media-qualified.
- Start, stop/start recovery, status, application rollback, and independent
  `cloudflared` service recovery are exercised separately.
- The receipt-bound media supervisor executes a hash-sealed manager copy from
  the retained release directory, not the mutable source checkout.

## Revisit triggers

- Remote users require reliable media.
- TURN/TLS or a managed LiveKit deployment is introduced.
- The server's LAN address or media ports change.
- Cloudflare Access is required for administrative surfaces.
- A second tunnel connector or application host is added for availability.
- The profile is proposed for internal production rather than controlled
  qualification.
