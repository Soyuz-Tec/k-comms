# ADR-0024: Add audio-only calls through a LiveKit media plane

- **Status:** Superseded for active implementation by ADR-0025
- **Date:** 2026-07-15
- **Owners:** Architecture, product, security, and platform
- **Reviewers:** Privacy, operations, and internal-pilot owners
- **Related requirements:** FR-COM-001, FR-ID-001, NFR-SEC-001, NFR-REL-001
- **Supersedes:** ADR-0009 for audio only
- **Superseded by:** ADR-0025 for the unified audio/video product and grant scope

ADR-0024 remains the historical record for the original audio-only boundary.
ADR-0025 preserves its lifecycle, expiry, authorization, and durable-eviction
decisions while replacing the audio-only media-source and user-experience scope.

## Context

K-Comms needs real-time voice communication without moving media through the
modular-monolith control plane or weakening tenant, conversation, session, and
device authorization. WebRTC media has different latency, network, privacy,
capacity, and recovery requirements from durable text messaging. The MVP
therefore reserved a separate media-plane phase in ADR-0009.

An internal pilot must support direct, group, and channel audio calls with
explicit microphone consent, mute, device selection, participant state,
reconnection, leave, and authorized end-for-everyone behavior. It must not
silently enable camera, recording, screen sharing, or arbitrary provider rooms.

## Decision

K-Comms remains the authoritative control plane. It persists the bounded call
lifecycle and every admitted provider participant identity, enforces tenant
policy and active conversation membership, audits commands, and broadcasts
content-free call availability. An admission binds the opaque provider identity
to the tenant, call, conversation, user, device, and session that authorized it,
plus issuance and eviction state. The signed participant token is transient and
is never persisted. K-Comms never proxies WebRTC media or accepts a provider
room name from a client.

LiveKit is the first audio media-plane adapter. A browser may receive a join
credential only from an authenticated K-Comms endpoint after current human
session, device, tenant, conversation, and membership checks succeed. The
credential:

- expires after at most five minutes and is kept in browser memory only;
- binds an opaque participant identity to tenant, user, device, and session;
- grants one exact server-derived room, room join, and subscription;
- permits publishing only the `microphone` track source; and
- explicitly denies data publication, metadata updates, room administration,
  recording, camera, and screen-share sources.

At most one active call exists per conversation. Every call has an eight-hour
maximum. Call creation atomically schedules one unique
`CommsWorkers.AudioCallExpiryWorker` Oban job at `expires_at`. At or after that
time the job locks the call, deletes the provider room, and then uses the same
ended audit, outbox, and participant-admission revocation path as an authorized
end-for-everyone command. Provider failure snoozes durable work for retry;
already-ended or superseded-call jobs safely do nothing. Starting an
already-active call is idempotent. Any active member may start or join; the
starter, a conversation owner, or a conversation moderator may end the call for
everyone. Leaving the media room affects only the local participant.

An access change commits without waiting for LiveKit. Session logout or
revocation, device revocation, password change or recovery, user suspension or
deletion, conversation membership removal, conversation archival, disabling
tenant audio, and applicable governance deletion first invalidate the durable
K-Comms authority and affected participant admissions. The same transaction
enqueues durable eviction work. A provider or transport failure may delay media
disconnection, but must never roll back or restore the revoked application
authority.

`CommsWorkers.AudioParticipantEvictionWorker` uses the stored opaque identity
to issue idempotent `RemoveParticipant` requests and durably records attempts.
Retryable failures remain queued. For self-hosted LiveKit the worker repeats
enforcement through at least
`AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS` (660 seconds by default;
660-1,800 in production) so a cached, still-unexpired participant token cannot
silently restore access after one successful removal. The enforcement window
must be at least the configured participant-token lifetime. The deadline is a
minimum repeat horizon, not a retry cutoff: failures continue durable retries
beyond it, and eviction completes only after a removal succeeds at or after the
horizon.

This portable self-hosted contract provides bounded, durable eviction, not
instantaneous token invalidation. A policy that requires strict immediate
single-participant revocation may require a separately implemented and
qualified LiveKit Cloud token-revocation capability. Without that capability,
deleting the whole room is the immediate hard-stop option and disconnects every
participant. K-Comms does not claim that cloud revocation path is implemented.

Call start and end metadata may use the existing authorized conversation and
user event channels. SDP, ICE candidates, audio frames, provider secrets, join
tokens, and raw provider metadata must never enter Phoenix events, audit rows,
application logs, URLs, durable browser storage, or operations responses.

Local development uses a digest-pinned loopback LiveKit server. Staging and
production consume separately provisioned provider endpoints and credentials.
Production activation requires trusted `wss://` signaling, ICE/UDP plus TCP
fallback, TURN/TLS on approved domains, secret rotation, provider isolation,
capacity and failure evidence, privacy approval, monitoring, and staffed
incident ownership.

Video, screen sharing, SIP, recording, transcription, and egress remain out of
scope and require a separate decision.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Relay audio through Phoenix | Reuses the existing realtime endpoint | Breaks media latency, capacity, and failure boundaries | Phoenix is a control and replay plane, not an RTP/SRTP media relay |
| Browser peer-to-peer mesh | No SFU service | Poor group scaling, NAT reliability, moderation, and observability | Does not meet reliable group/channel calling requirements |
| Permanent room per conversation with no call record | Minimal persistence | No bounded lifecycle, policy audit, incoming-call state, or authoritative end | Insufficient operational and authorization control |
| Enable LiveKit video grants now | One provider supports both | Expands privacy, UI, bandwidth, and production scope | Audio is the approved requirement; video remains deferred |
| Build a custom SFU | Full control | High protocol, security, interoperability, and operations cost | No differentiating requirement justifies a custom media server |

## Consequences

### Positive

- Media scaling and failures remain isolated from durable messaging.
- Existing tenant and conversation authorization remains authoritative.
- Source-restricted tokens enforce audio-only behavior below the UI layer.
- The provider boundary can move between self-hosted LiveKit and a managed
  LiveKit deployment without changing the call domain model.

### Negative and accepted trade-offs

- The platform gains a latency-sensitive external runtime and browser SDK.
- Self-hosted token revocation is not instantaneous by token alone. Tokens stay
  short lived, lifecycle endpoints stop issuing replacements, and durable
  repeated eviction bounds cached-token replay rather than promising an
  immediate disconnect.
- Browser permission, autoplay, device, NAT, and firewall behavior introduces
  failure states that need explicit product handling and qualification.
- Local loopback success is not evidence of production TURN/TLS or multi-region
  readiness.

### Operational consequences

- The media plane needs independent health, join-failure, reconnect, packet
  loss, jitter, round-trip-time, bandwidth, and TURN telemetry without tenant,
  user, token, or room labels.
- Runbooks must distinguish control-plane, signaling, ICE, TURN, microphone,
  autoplay, and device failures.
- PostgreSQL and LiveKit recovery are independent; a media outage must degrade
  audio without making text messaging unready.
- Provider eviction failure is observable durable work. Operators must track
  pending/enforcing admissions and oldest retry age without logging room names,
  participant identities, tokens, or user identifiers.

### Security and privacy consequences

- Provider API secrets remain backend-only and externally managed.
- Microphone access is allowed only for the first-party application origin;
  camera remains prohibited by Permissions Policy.
- The baseline does not record, transcribe, or persist audio.
- Cross-tenant substitution, removed membership, inactive identity, expired
  call, arbitrary room, overbroad grant, token replay, and secret logging tests
  are mandatory.
- Persist only the opaque admission identity and authorization bindings needed
  for eviction. Participant JWTs, provider API secrets, and raw user media must
  never enter the admission record, Oban arguments, audit evidence, or logs.

## Validation

- Core and controller tests prove lifecycle idempotency, concurrency, tenant
  isolation, membership reauthorization, policy disablement, expiry, and end
  permissions.
- Token tests verify signature, expiry, opaque identity, exact room, and the
  microphone-only grant set.
- Revocation tests prove that each supported access-change transaction commits
  and rejects new joins independently of provider availability; its durable job
  retries and repeatedly removes the exact stored participant identity through
  the configured enforcement window without persisting or logging a token.
- Expiry tests prove call creation atomically schedules one unique job for the
  exact `expires_at`; early, already-ended, and superseded jobs are harmless,
  while provider failure retries and eventual success produces one normal
  ended lifecycle plus participant eviction work.
- Browser tests cover explicit consent, join muted, mute/unmute, input-device
  changes, remote audio attachment, autoplay recovery, reconnect, leave, remote
  end, permission denial, keyboard operation, and responsive accessibility.
- A two-participant qualification proves bidirectional audio media and inbound
  RTP growth, not only room presence.
- Production evidence separately covers trusted TLS, UDP/TCP/forced-TURN paths,
  provider failover, capacity, privacy review, incident routing, and secret
  rotation. It also measures access-change-to-disconnect latency, cached-token
  replay resistance, retry recovery, and the selected strict-revocation policy.

## Revisit triggers

- Video, screen sharing, recording, transcription, SIP, or external dial-in is
  approved.
- Call scale or geography requires multi-region media routing.
- Provider isolation, residency, or availability requirements cannot be met by
  the selected deployment.
- Stronger media end-to-end encryption or cryptographic identity binding is
  required.
