# ADR-0067: Add durable messaging receipts and authorized call collaboration controls

- **Status:** Accepted
- **Date:** 2026-08-02
- **Owners:** Messaging, calls, collaboration, web, and operations
- **Reviewers:** Architecture, security, privacy, and reliability
- **Related requirements:** FR-MSG-001, FR-MSG-003, FR-SRCH-001, FR-COM-001, FR-COL-001, FR-SYNC-001

## Context

The workspace needs cross-device delivery/read evidence, links between messages
and selected whiteboard objects, unified authorized search/activity views, and
in-call raise-hand, reaction, participant mute/remove, speaker selection, and
quality feedback. These features must not make Phoenix or LiveKit authoritative
for durable business state, expose provider identities as public domain data,
or expand the recording and transcription scope rejected by ADR-0025.

## Decision

ConversationContent owns typed message metadata for bounded whiteboard
references and HTTPS links. The server validates but never fetches or unfurls
submitted URLs. ConversationContent also owns one monotonic delivery/read
cursor per tenant, conversation, user, and device. The existing conversation
membership read cursor remains the authoritative unread-count boundary.

Unified search and activity are authorized, read-time projections composed by
the web adapter from owner facades. They create no shared persistence model and
do not permit one context to import another context's schemas.

Calls owns durable participant admission, raised-hand state, authorization,
moderation targets, audit coordination, and revocation/eviction scheduling. A
dedicated `call:<call_id>` Phoenix topic accelerates raised-hand and allowlisted
reaction delivery and reauthorizes both inbound and outbound traffic. Reactions
are bounded and ephemeral. LiveKit remains the media plane: its server API
enforces exact-room mute/remove actions, while participant removal is persisted
and queued before best-effort immediate provider enforcement. Provider room,
identity, token, SDP/ICE, and media data remain private infrastructure values.

Speaker selection and connection-quality labels are client-side, content-blind
media controls. Recording, transcription, and LiveKit data-channel publication
remain disabled. No new GenServer, supervisor, or process ownership boundary is
introduced; PostgreSQL and the existing worker supervision retain their current
fault-tolerance and ordering semantics.

The two additive migrations remain owner-cohesive: one ConversationContent
migration creates delivery cursors and one Calls migration adds raised-hand
state. Old application images ignore both additions, and production rollback
must not run destructive down migrations.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Use LiveKit data channels for all collaboration | Low initial adapter work | Provider becomes a signaling dependency; no durable hand state; conflicts with disabled data publication | Violates the media-plane boundary and recovery model |
| Store one shared workspace activity table | Simple chronological query | Duplicates owner state and creates cross-context writes and consistency repair | Owner projections are sufficient and safer |
| Fetch link previews on message acceptance | Rich previews | Introduces SSRF, redirect, egress, privacy, and latency risk in the message transaction | Validated client-rendered links meet the requirement without network side effects |
| Remove participants only at the provider | Immediate effect | Revocation is lost on provider failure or process crash | Persist-first revocation and durable eviction preserve convergence |

## Consequences

### Positive

- Delivery/read evidence survives reconnects and is monotonic per device.
- Messaging, whiteboard, file, and call activity can be discovered without
  moving ownership or duplicating source-of-truth state.
- Moderation converges after provider failures and every durable action remains
  authorized and auditable.
- Media signaling and business collaboration remain separately testable.

### Negative and accepted trade-offs

- Activity reads compose several bounded owner queries rather than one table.
- Per-device cursors add write volume and expose only a hashed device reference
  to other authorized participants.
- Reactions may disappear during a socket outage because they are not business
  records.

### Operational consequences

- Migration qualification must verify both owner-cohesive additive migrations.
- LiveKit room-service health affects immediate mute/remove enforcement;
  participant removal still converges through the existing media worker.
- Production qualification still requires the separately governed forced-TURN,
  group-capacity, screen-share, outage, and incident-routing gates.

### Security and privacy consequences

- Only HTTPS links without userinfo are accepted; the server performs no URL
  request.
- Every call command and outbound event rechecks session and conversation/call
  authority.
- Public responses exclude provider rooms, provider identities, credentials,
  and media telemetry that could identify infrastructure.
- Recording and transcription remain explicitly off.

## Validation

- Unit tests cover metadata bounds and URL/region rejection.
- Integration tests cover monotonic bounded delivery cursors, authorization,
  raised hands, moderator removal, audit, durable eviction, and exact LiveKit
  mute/remove requests.
- Channel tests cover admitted join, reactions, raised hands, and post-revocation
  outbound denial.
- Client tests cover metadata cards, search, media controls, reconnect/teardown,
  accessibility, type checking, linting, and production build.
- Architecture, OpenAPI, AsyncAPI, JSON Schema, documentation, migration, and
  full regression validators must pass before protected merge.

## Revisit triggers

- A product requirement makes reactions durable or introduces recording or
  transcription.
- Delivery-cursor volume requires aggregation or partitioning.
- Activity composition exceeds its bounded latency budget.
- LiveKit moderation semantics cannot provide exact-room enforcement.
