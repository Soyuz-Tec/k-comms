# ADR-0025: Unify audio and video calls on the LiveKit media plane

- **Status:** Accepted for implementation and internal pilot
- **Date:** 2026-07-15
- **Owners:** Architecture, product, security, privacy, and platform
- **Reviewers:** Accessibility, operations, and internal-pilot owners
- **Related requirements:** FR-COM-001, FR-ID-001, NFR-SEC-001, NFR-REL-001
- **Supersedes:** The audio-only product and grant scope of ADR-0024

## Context

ADR-0024 introduced a bounded audio-call lifecycle and a separate LiveKit media
plane. K-Comms now needs camera-based one-to-one and group communication without
duplicating that lifecycle, weakening conversation authorization, or turning
Phoenix into a media relay. Video also introduces more sensitive capture,
greater bandwidth and device load, screen-sharing disclosure risk, and layout
and accessibility requirements that audio-only operation did not cover.

The existing durable call and participant-admission model already provides the
right authority boundary: one active call per conversation, server-derived
provider rooms and identities, short-lived grants, an eight-hour deadline,
audited end-for-everyone, and durable access-change eviction. Reusing that model
avoids two competing call states and makes a call's media kind explicit.

## Decision

`audio_calls` remains the implementation aggregate and gains a required
`media_kind` of `audio` or `video`. The name is retained as a compatibility and
migration boundary; public contracts describe it as a call. A conversation can
have at most one active call of either kind. Its media kind cannot change after
creation. A request for a different kind while a call is active conflicts
rather than mutating the provider grants of a live room.

The canonical authenticated routes are:

- `GET /api/v1/conversations/{conversation_id}/call`;
- `POST /api/v1/conversations/{conversation_id}/calls` with
  `{ "media_kind": "audio" | "video" }`;
- `POST /api/v1/conversations/{conversation_id}/calls/{call_id}/join`; and
- `POST /api/v1/conversations/{conversation_id}/calls/{call_id}/end`.

The existing `audio-call` and `audio-calls` routes remain deprecated aliases
that start and operate audio calls. Responses and content-free
`call.started.v1` / `call.ended.v1` realtime events include `media_kind`.
`allow_audio_calls` and `allow_video_calls` are independent tenant policies;
the public service status advertises `audio_calls` and `video_calls`
independently.

K-Comms remains the authorization and lifecycle control plane. LiveKit remains
an ephemeral signaling and WebRTC SFU plane. Every participant token is
room-scoped, short lived, non-administrative, denies data publication and
metadata mutation, and subscribes only within its exact call room. Publication
grants are selected server-side:

- audio calls permit only `microphone`; and
- video calls permit only `microphone`, `camera`, `screen_share`, and
  `screen_share_audio`.

No client may choose a provider room, participant identity, grant, or track
source. Provider API credentials remain backend-only. Participant tokens remain
in browser memory and are never persisted by K-Comms.

The web client supports direct and group calls through the same responsive
surface. Video joins use an explicit prejoin step with camera and microphone
off until the user chooses otherwise, a self-preview, device selectors, clear
camera/microphone state, participant tiles, active-speaker indication, and a
responsive grid. Screen sharing requires a separate user action, remains
visibly indicated, and stops on leave, end, session loss, track end, or
component teardown. The shared screen is prioritized without hiding access to
participant state. Audio-only callers remain represented in the grid without a
fake video feed.

Video does not change lifecycle or revocation semantics. Calls retain the
durable eight-hour expiry job. Session, device, user, membership, conversation,
tenant-policy, and governance access changes invalidate admissions and enqueue
durable participant removal. Self-hosted LiveKit eviction is repeated through
the configured 660-1,800 second enforcement horizon and failures continue to
retry until a removal succeeds at or after the horizon. This bounds cached-token
replay but does not claim instantaneous token invalidation.

Camera, microphone, screen, SDP, ICE, RTP/SRTP, provider token, and raw provider
metadata never enter Phoenix events, application logs, audit rows, URLs,
durable browser storage, or support responses. The baseline does not record,
transcribe, snapshot, or persist media. Permissions Policy allows camera and
microphone only to the first-party application origin. Browser capture status
must remain visible and native permission revocation must fail closed.

Local Compose provides a digest-pinned, loopback, same-host proof for direct and
group media. It is not production network or capacity evidence. Staging and
production use a separately provisioned LiveKit endpoint. Production activation
requires trusted HTTPS/WSS, ICE/UDP and ICE/TCP, restricted TURN/TLS, approved
domains and certificates, bandwidth and participant-capacity tests at expected
group size plus headroom, reconnect and forced-relay evidence, privacy and
consent approval, content-blind telemetry, secret rotation, and staffed incident
ownership. The portable Kubernetes overlays do not deploy LiveKit or TURN.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Decision |
|---|---|---|---|
| Separate audio and video aggregates | Independent product evolution | Conflicting active state, duplicate authorization, expiry, and eviction paths | Rejected |
| Peer-to-peer mesh for video | Minimal provider infrastructure for two users | Group upload grows per peer; NAT, moderation, and observability degrade | Rejected |
| Publish unrestricted LiveKit tracks | Less token logic | Enables unapproved data or future sources and weakens defense in depth | Rejected |
| Route video through Phoenix | Reuses the application endpoint | Violates control/media separation and cannot meet interactive media budgets | Rejected |
| Record calls by default | Playback and compliance convenience | Changes data purpose, consent, retention, legal, storage, and breach impact | Rejected |

## Consequences

### Positive

- Direct and group audio/video share one authoritative, testable lifecycle.
- Server-selected source grants enforce media kind below the UI.
- Tenant administrators can disable video without disabling audio.
- SFU forwarding avoids peer-mesh group scaling while keeping media failures
  isolated from durable messaging.
- Deprecated audio routes preserve deployed-client compatibility.

### Negative and accepted trade-offs

- Camera and screen capture increase privacy, accessibility, bandwidth, battery,
  thermal, and incident-response obligations.
- Group quality depends on provider capacity, participant devices, and network
  paths that local same-host tests cannot establish.
- Self-hosted participant removal remains bounded rather than instantaneous.
- The historical `audio_calls` storage/module name no longer describes every
  media kind; renaming it now would add migration risk without improving the
  trust boundary.

### Operational consequences

- Media dashboards need aggregate join, publish, subscribe, reconnect, packet
  loss, jitter, round-trip time, bitrate, resolution, frame-rate, CPU-limited,
  bandwidth-limited, and TURN indicators without room or user labels.
- Runbooks distinguish camera permission/device failure, screen-share failure,
  decode/render load, bandwidth adaptation, and group-capacity saturation from
  control-plane and signaling failure.
- Capacity is approved per environment from representative direct and group
  tests. This decision does not invent a portable hard participant limit.
- A media outage degrades calls but must not make text messaging unready.

## Security and privacy consequences

- Video and screen capture are Restricted live data even though K-Comms does
  not persist them. Call lifecycle and opaque admissions remain Confidential.
- Screen sharing may expose unrelated applications or notifications; pre-share
  education, browser-native source selection, persistent sharing indication,
  and an immediate stop action are required.
- No recording, egress, transcription, SIP, arbitrary data channel, background
  capture, or cross-room subscription is authorized by this decision.
- Cross-tenant substitution, media-kind substitution, overbroad grant, removed
  membership, inactive identity, cached-token replay, camera-without-consent,
  and screen-track cleanup are mandatory negative tests.

## Validation

- Contract tests prove canonical routes, deprecated audio aliases,
  `media_kind`, independent tenant policy, service capability reporting, and
  `call.started.v1` / `call.ended.v1` payload compatibility.
- Token tests decode signed grants and prove exact room identity, five-minute
  maximum lifetime, audio microphone-only publication, video publication of
  exactly microphone/camera/screen-share/screen-share-audio, and denial of data,
  administration, recording, and metadata mutation.
- Browser tests cover explicit prejoin, default-off camera/microphone, preview,
  device changes, mute/camera toggles, group grid, speaking state, screen-share
  start/stop, permission denial, autoplay, reconnect, leave, remote end,
  teardown, keyboard behavior, and responsive accessibility.
- Live qualification proves bidirectional audio and video RTP for two users,
  at least three participants in one group room, visible group-state changes,
  screen-share publication/subscription, member/session revocation, rejected
  rejoin, expiry, and end-for-everyone.
- Production evidence separately proves WSS/HTTPS, UDP/TCP/forced TURN/TLS,
  expected group size plus headroom, adaptive degradation, provider outage and
  recovery, privacy approval, incident routing, and secret rotation.

## Rollback

Disable `allow_video_calls` for pilot tenants first. Existing video calls are
ended through the normal room-deletion and admission-revocation path; do not
relabel them as audio. Keep audio enabled and retain the canonical read/join/end
routes plus deprecated audio aliases. If the unified release must roll back,
deploy the prior application only after all active video calls have ended and
the database migration is confirmed backward compatible. Do not drop
`media_kind` or erase call/audit evidence during rollback.

## Revisit triggers

- Recording, transcription, SIP, external dial-in, provider egress, or data
  channels are approved.
- Media end-to-end encryption or cryptographic participant identity is required.
- Multi-region routing, residency, maximum group size, or webinar/broadcast
  behavior exceeds the qualified provider composition.
- Privacy policy requires stricter per-participant instantaneous revocation than
  the self-hosted bounded-eviction contract provides.
