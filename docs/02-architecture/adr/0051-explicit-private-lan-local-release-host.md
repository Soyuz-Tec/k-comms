# ADR-0051: Use a host forwarder for explicit private-LAN release access

- **Status:** Accepted
- **Date:** 2026-07-25
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0008, ADR-0025, ADR-0047, ADR-0050, ADR-0053

## Context

ADR-0047 keeps the packaged local release on loopback. That remains the safest
default for exact-image qualification on one workstation. A controlled
evaluation sometimes needs another device on the same private network to open
the packaged K-Comms UI, and `127.0.0.1` on that device refers to the device
itself.

Publishing Podman Desktop ports directly on a Windows RFC1918 address is not an
acceptable solution. Podman runs through a managed VM/WSL networking boundary;
direct host-IP publication is unreliable on supported Windows setups and would
also make the container publication itself the LAN security boundary.
Wildcard publication would expose every interface. Either approach would make
the loopback-only invariant difficult to verify and rollback safely.

Allowing arbitrary clear-text hosts would also turn a local qualification
exception into a production-origin bypass. DNS names, public addresses,
forwarded-host values, or inconsistent application, media, object, CORS, and
CSP hosts make the effective browser boundary ambiguous.

## Decision

Keep Podman publication loopback-only and add a manager-owned Windows host
forwarder for the explicit private-LAN mode.

1. `-BindAddress` remains an explicit public-host selection. It accepts only
   canonical `127.0.0.1` or one locally assigned RFC1918 IPv4 address.
   Wildcard, DNS, public, carrier-grade NAT, link-local, multicast, IPv6,
   whitespace, and alternate numeric forms fail closed.
2. Compose uses the distinct `K_COMMS_PODMAN_BIND_ADDRESS` setting for every
   application, MinIO API, and LiveKit TCP/UDP publication. Its only permitted
   value is `127.0.0.1`. PostgreSQL remains unpublished and the MinIO console
   remains explicitly bound to `127.0.0.1`. Every manager-owned Compose call
   seals all retained and referenced interpolation variables from the retained
   environment, clears absent referenced variables, forces the Podman bind to
   loopback, and restores the caller's process environment afterward. Ambient
   shell values cannot widen or rewrite the sealed topology.
3. In LAN mode, `PHX_HOST`, `PUBLIC_APP_URL`, browser-facing
   `LIVEKIT_SERVER_URL`, `S3_PUBLIC_ENDPOINT`, CORS, CSP, and LiveKit
   `--node-ip` still use the exact selected RFC1918 public host. The internal
   LiveKit API remains exactly `http://livekit:7880`.
4. The manager retains and hash-verifies
   `scripts/lan_release_forwarder.mjs`, starts it with
   `node <retained-script> --config <retained-config>`, and waits for its
   authenticated readiness record. The forwarder binds only the selected
   RFC1918 address and maps the following same-number ports to
   `127.0.0.1`:

   | Listener | Protocol |
   |---|---|
   | application | TCP |
   | MinIO browser API | TCP |
   | LiveKit signaling | TCP |
   | LiveKit RTC fallback | TCP |
   | LiveKit RTC media | UDP |

   The forwarder has bounded TCP connection, timeout, backlog, socket-buffer,
   UDP mapping, idle-time, and pending-datagram limits. It is not a wildcard
   proxy, an HTTP trust proxy, a TLS terminator, or a firewall manager.
5. The forwarder writes readiness only after all five listeners are bound. Its
   atomic ready record binds the process ID and start time, selected address,
   exact configuration SHA-256, unguessable readiness token, and observed
   listener set. The same structured readiness event is written to its
   retained stdout log. Fatal startup/runtime events are also structured;
   manager-initiated Windows process termination is not claimed as graceful
   application shutdown.
6. Schema-v5 receipts record:

   - `network.bindAddress` and `network.publicHost` as the exact selected
     public host;
   - `network.podmanBindAddress` as exactly `127.0.0.1`;
   - `network.exposureMode` as `loopback` or `lan-forwarder`; and
   - `forwarder.required`, retained script/config paths and hashes, ready/log
     paths, readiness token, and exact listener contract.

   The PID is runtime evidence in the ready record, not immutable receipt
   identity. `Start` may safely create a replacement process. Schema-v3 and
   schema-v4 receipts remain compatible only for loopback activation.
7. `Deploy`, `Start`, restore, and `Rollback` verify the retained forwarder
   assets and configuration before use. LAN activation first proves local
   container health through `127.0.0.1`, then starts the forwarder, validates
   its current identity/hash/listeners, and probes the selected public address.
   A mismatch or partial startup fails closed and stops only the matching
   managed forwarder. `Stop` also stops the matching forwarder without broad
   process termination.
8. `Status` reports exactly `Forwarder: not-required` for loopback. LAN status
   must report `Forwarder: ready`,
   `Observed forwarder matches receipt: True`, and
   `Observed forwarder configuration hash matches receipt: True` before
   packaged qualification can pass.
9. Windows LAN orchestration still requires the selected address to be
   `Preferred` on exactly one interface and to resolve to exactly one network
   profile. A **Private** profile is accepted by default. A non-Private
   category requires the explicit audited `-AllowPublicNetworkProfile`
   override.
10. The manager never creates, modifies, narrows, or removes Windows Firewall
    rules. The profile check and override are evidence and risk controls, not
    proof that existing firewall policy is safe.
11. Clear-text RFC1918 HTTP qualification always uses `-LanTextOnly`. It proves
    the retained image, forwarder, application, packaged UI, and text/guest
    flows, but skips audio and video and explicitly states that media was not
    qualified. HTTP/WS authentication, session, and join tokens, messages, and
    file links can be observed or modified on-path, so this mode is controlled
    evaluation with no sensitive data. Trusted HTTPS/WSS is mandatory for
    internal production. Browser media must never be claimed from a plain HTTP
    LAN IP. Reliable remote media also requires, where applicable, TURN/TLS.
12. The fixed instant-room tenant is provisioned through a loopback-only
    one-shot release command before the forwarder starts. Every application
    activation forces `ALLOW_BOOTSTRAP=false`, and LAN qualification requires
    `/api/v1/status` to report `bootstrap=false`.
13. On an explicit clear-text LAN release, the browser clears retained member
    credentials and disables sign-in, recovery, invitation acceptance, account
    conversion, and audio/video controls. The server independently rejects the
    corresponding credential and media operations with HTTP `426
    secure_transport_required`. The LAN release makes no loopback exception:
    the raw TCP forwarder cannot prevent a remote client from spoofing a
    loopback `Host` header. Only the actual request scheme, never
    caller-supplied `Host` or `Origin` headers, can establish HTTPS. Operator
    credential workflows therefore require a separately deployed loopback
    profile or trusted HTTPS; a future terminating proxy must expose that
    scheme through a separately validated trusted-proxy contract.
14. Interrupted disposable qualification cleanup is state-root global but
    remains bound to the release that created it. Its secret-free schema-v3
    marker records the disposable tenant and isolated app identity plus the
    originating retained receipt, environment, Compose, project, revision, and
    image paths/hashes/identities. Recovery validates those exact history
    assets and the local image, removes and confirms the isolated app absent,
    deletes the tenant with the originating Compose context, then deletes the
    marker last. Exact legacy schema-v2 tenant-only markers remain recoverable.
    Recovery never substitutes the currently active candidate and never
    persists a tenant password or release secret.

The ordinary production path is unchanged. Without
`K_COMMS_LOCAL_RELEASE=true`, application and provider origins continue to
require their existing HTTPS/WSS production validation.

## Consequences

### Positive

- Podman remains verifiably loopback-only in both local and LAN modes.
- A packaged K-Comms UI can use one real RFC1918 server address without
  wildcard container publication.
- Public browser origins remain exact and consistent across application,
  WebSocket, LiveKit, object storage, CORS, and CSP configuration.
- Hash-bound configuration and readiness tokens distinguish the current
  managed forwarder from a stale or unrelated process.
- Stop, restart, rollback, and qualification share one receipt-bound lifecycle.

### Negative and accepted trade-offs

- LAN mode adds a manager-owned host process and five host listeners.
- The manager verifies and replaces that process during lifecycle actions, but
  it is not a continuous supervisor or Windows service. An unexpected process
  exit makes Status and qualification fail until an operator runs Start again.
- The forwarder is single-host evaluation infrastructure, not a production
  ingress, load balancer, or TURN service.
- An operator can explicitly authorize a non-Private Windows profile. That is
  a recorded risk acceptance, not a claim that the network or firewall is safe.
- Clear-text LAN mode cannot qualify browser microphone, camera, or reliable
  WebRTC media.
- Forwarder readiness proves the Node UDP listener and its receipt identity; it
  does not prove that Windows `127.0.0.1:7982` reaches LiveKit through the
  Podman/WSL boundary. On the evaluated host no Windows UDP endpoint was
  observable and the STUN probe failed, so media must not be inferred from
  `Forwarder: ready`.
- Existing schema-v4 LAN receipts must be replaced by a schema-v5 deployment;
  only legacy loopback receipts remain compatible.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Publish Podman ports directly on the RFC1918 host address | Unreliable across the Windows Podman networking boundary and weakens the loopback-only invariant. |
| Publish Podman ports on `0.0.0.0` | Exposes every interface and is broader than the selected private host. |
| Detect and select a LAN address automatically | Network selection becomes implicit and may change across adapters or boots. |
| Accept a private DNS name | DNS resolution and rebinding make the exact clear-text browser boundary harder to verify. |
| Configure Windows Firewall automatically | Host firewall policy is operator-owned, environment-specific state outside this release manager's authority. |
| Claim audio/video from plain HTTP LAN qualification | Browser secure-context behavior makes the result unreliable and misleading. |
| Relax production HTTPS/WSS checks | A local evaluation need does not justify weakening production transport security. |

## Validation

- `python scripts/test_validate_local_release.py`
- `python scripts/validate_local_release.py`
- `python scripts/test_qualify_local_release.py`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/qualify_local_release.ps1 -SelfTest`
- `node --test scripts/lan_release_forwarder.test.mjs`
- `python scripts/validate_docs.py`
- Tests reject wildcard, direct RFC1918, legacy bind variables, and missing
  loopback defaults in every Podman-published port.
- Tests reject LAN receipts without schema-v5 forwarder evidence and reject
  stale identity, configuration-hash, readiness-token, or listener evidence.
- Tests require `Forwarder: not-required` for loopback and the complete current
  forwarder status gate for LAN.
- Tests prove that plain RFC1918 HTTP can run only as text-only qualification
  and never reports audio/video as qualified.

## Revisit triggers

- Local qualification moves behind a trusted TLS ingress.
- LiveKit/TURN topology or browser secure-context requirements change.
- Podman Compose or the supported Windows networking model changes.
- The forwarder is replaced by an approved managed ingress.
