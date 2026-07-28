# ADR-0057: Use managed LiveKit Cloud for Internet media transport

- **Status:** Accepted
- **Date:** 2026-07-27
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0012, ADR-0047, ADR-0054, ADR-0055

## Context

ADR-0054 deliberately limited the trusted-edge release to same-LAN audio and
video. Cloudflare Tunnel carries application HTTP and signaling WebSockets,
but it does not proxy LiveKit's raw WebRTC ICE media ports. A mobile device on
the public Internet can therefore load K-Comms while its audio or video never
establishes a usable media path.

Publishing the existing LiveKit TCP and UDP ports from the residential edge
would require public routing, NAT/firewall changes, a stable reachable
address, TURN, certificate and abuse controls, and ongoing operational
ownership. The selected first increment must remain no-cost at current pilot
usage and must not weaken the VM firewall or expose the Proxmox network.

## Decision

Use LiveKit Cloud's free Build plan as the managed signaling, ICE, and TURN
provider for the K-Comms pilot. Maintain separate `k-comms-staging` and
`k-comms-production` LiveKit projects and credentials so a lower-trust
environment cannot mint production participant tokens or administer
production rooms.

The application continues to mint short-lived participant tokens and invoke
the LiveKit Room Service from the K-Comms backend. Browsers receive only the
public WSS endpoint and a scoped participant token; API secrets remain in the
protected runtime configuration.

The Proxmox deployment contract uses:

- `K_COMMS_LIVEKIT_TOPOLOGY=managed_cloud`;
- `K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=livekit-cloud-v1`;
- an exact `wss://<project>.livekit.cloud` participant endpoint;
- the matching exact `https://<project>.livekit.cloud` server API endpoint;
- a protected GitHub environment secret named
  `K_COMMS_LIVEKIT_CLOUD_CREDENTIAL`.

The deployment workflow materializes that JSON credential only on the
protected deployment runner, restricts its ACL, transfers it as a mode-`0600`
temporary file, and removes both local and remote temporary copies. The VM
deployment validates the credential shape, atomically updates only the
application-facing LiveKit and CSP fields, and restores the preceding
`runtime.env` if activation or verification fails. Credentials are never
placed in Git, receipts, command-line arguments, or logs.

Keep the existing self-hosted LiveKit Quadlet running behind the LAN-only
firewall as a rollback standby for this increment. K-Comms does not use that
sidecar while `managed_cloud` is active. Retaining it avoids an unrelated host
topology change during the media-provider cutover and preserves the reviewed
same-LAN rollback path.

## Consequences

Internet participants can negotiate media through LiveKit Cloud without
opening inbound ICE or TURN ports on the production network. The free
allowance is suitable for the current pilot, but it is a shared account quota
and service may be limited when the provider's free-plan caps are reached.
Usage and connection success must therefore be monitored in LiveKit Cloud.

The application now depends on LiveKit Cloud availability and outbound
Internet connectivity. Media metadata and transport are processed by that
provider under its service terms. Agent observability remains disabled; this
decision does not enable recording, transcription, egress, telephony, or an
agent workload.

Rollback can restore the previous runtime configuration and same-LAN
self-hosted media, but that rollback also restores the former Internet-media
limitation.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Publish the VM's LiveKit ICE ports directly | It adds residential NAT, public address, TURN, certificate, abuse, and firewall operations and is not a dependable no-cost Internet path. |
| Proxy media through Cloudflare Tunnel | Cloudflare Tunnel does not carry the raw UDP/TCP ICE transport required by self-hosted LiveKit. |
| Operate a free TURN VM | A durable public VM, bandwidth, patching, monitoring, certificates, and abuse response are still required; the nominal software cost is not the operating cost. |
| Rebuild calls on peer-to-peer WebRTC | It removes the existing LiveKit room, moderation, revocation, and group-call contract and is a broad product rewrite. |
| Share one LiveKit project across staging and production | It collapses credential and room administration boundaries between environments. |

## Validation

- Static validation requires the protected environment secret, strict
  credential handling, managed topology confirmation, runtime rollback, and a
  non-secret receipt field.
- Unit tests cover trusted-edge and private-LAN managed endpoints, exact
  confirmation, matching WSS/HTTPS hosts, and CSP restrictions.
- Staging must deploy the attested `main` digest, pass application readiness,
  reach the managed LiveKit endpoint, and complete audio/video qualification
  before production approval.
- Production must deploy the same digest, retain backup and receipt evidence,
  pass public health/status checks, and prove a two-party call with one
  participant outside the local network.

The production two-party requirement passed on 2026-07-27. Two physical
iPhones joined with Wi-Fi disabled, published and subscribed to microphone and
720p camera tracks, and exchanged media over the managed provider's UDP path.
The retained evidence is
[Production external-media qualification — 2026-07-27](../../11-testing-and-quality/external-media-qualification-2026-07-27.md).

## Revisit triggers

- Free-plan quota, concurrency, bandwidth, or retention policy no longer fits
  the pilot.
- Recording, transcription, telephony, regulated data, or a formal media SLA
  is introduced.
- The local standby is retired or a tested self-hosted Internet/TURN topology
  replaces the managed provider.
