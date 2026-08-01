# ADR-0063: Add conversation whiteboards through a replaceable Excalidraw adapter

- **Status:** Accepted
- **Date:** 2026-08-01
- **Owners:** Collaboration, Web, Security, and Operations
- **Related requirements:** FR-COL-001, FR-RT-001, FR-SYNC-001, ADR-0002,
  ADR-0003, ADR-0007, ADR-0040, ADR-0045

## Context

K-Comms needs a shared visual workspace for diagrams, planning, and free-form
collaboration. The capability must preserve conversation authorization,
multi-device replay, tenant isolation, and acknowledged-write durability. An
editor SDK can provide mature drawing interaction, but it must not become the
authority for identity, persistence, ordering, or realtime access.

## Decision

The Collaboration context owns one durable whiteboard per conversation through the
`CommsCore.Whiteboards` facade. PostgreSQL stores a board sequence and an
append-only operation log. A `scene.update` operation carries a bounded batch of
Excalidraw elements; `board.clear` advances the same sequence and defines the
fresh-replay boundary. Every accepted write authorizes an active workspace
human membership, locks the board row, allocates one canonical sequence, and
commits the operation and sequence together.

Clients supply an 8-to-128-byte idempotency key scoped to tenant, device, and
conversation. Replaying the same key and content returns the original
operation; reusing it for different content fails with a conflict. Fresh replay
starts at the latest clear while incremental replay remains sequence-based.
Each scene update also carries the client's last applied board sequence. Inside
the locked transaction, the server rejects an update whose base sequence is
older than the latest clear, so a delayed or in-flight edit cannot resurrect a
scene that another collaborator cleared.
Boards are capped at 100,000 durable operations; each update is capped at 200
elements, 512,000 encoded bytes, and 64,000 bytes per element.

Phoenix uses a dedicated `whiteboard:{conversationId}` topic. Durable changes
are acknowledged over REST and broadcast only after commit. Pointer and
selection presence is ephemeral, bounded, and never treated as delivery or
history authority. Join, inbound presence, and every intercepted outbound
operation or presence event reauthorize the session and membership. This
introduces no GenServer, supervisor, registry, process owner, or LiveKit data
channel; existing endpoint supervision and PubSub semantics remain unchanged.

The React client embeds the exact `@excalidraw/excalidraw` 0.18.1 SDK behind a
lazy-loaded feature route. Excalidraw is a replaceable editor engine, not a
forked K-Comms subsystem. K-Comms owns the REST/channel adapter, deterministic
scene projection, persistence, retry, and authorization. Equal-version
concurrent edits use Excalidraw's lower-version-nonce rule. Image, embeddable,
link, and custom-data persistence is disabled for this first slice; supported
elements are rectangles, diamonds, ellipses, lines, arrows, free drawing, text,
and frames. Nested vulnerable transitive packages are pinned through reviewed
npm overrides and the production build remains the compatibility gate.

Whiteboards are initially available only to authenticated workspace humans who
are active conversation members. Guest, instant-room, and service-principal
access requires a separate interface, history-boundary, abuse, and lifecycle
decision.

Whiteboard elements and text are Restricted content. They inherit conversation
legal-hold, deletion, backup, and access-handling rules. User erasure
neutralizes scene-update payloads authored by that user; conversation erasure
removes the board and operation log inside the existing governance transaction.
Clearing is a collaborative content operation, not a retention deletion. A
board is a persistent document rather than a message-age stream; automatic
history compaction requires a later snapshot-preserving decision.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Rewrite or fork Excalidraw | Total editor control | Large permanent editor, accessibility, and security maintenance burden | K-Comms differentiates in collaboration authority, not drawing primitives |
| Persist opaque full-scene snapshots only | Simple reads | Lost operation ordering, weak idempotency, larger concurrent overwrites | Does not meet deterministic collaboration and replay requirements |
| Send whiteboard data through LiveKit | Reuses a realtime connection | Couples durable content to an ephemeral media plane and room lifecycle | LiveKit is not K-Comms content authority |
| Add a whiteboard GenServer per room | Fast in-memory coordination | Adds process ownership, cluster routing, restart, and mailbox semantics | PostgreSQL plus PubSub meets the current durability and ordering need |

## Consequences

### Positive

- Visual collaboration uses the same tenant, conversation, and session trust
  boundary as other durable content.
- Editor replacement remains possible without migrating authorization or API
  ownership.
- Durable replay and idempotency cover disconnects, retries, and multi-device
  use while cursor presence stays inexpensive and ephemeral.

### Negative and accepted trade-offs

- The whiteboard route downloads a substantially larger lazy feature bundle.
- The append-only log consumes more rows than last-scene-only persistence.
- Images, external links, embeds, guest access, and service automation are
  intentionally unavailable in the first production slice.

### Operational consequences

The additive migration creates `whiteboards` and `whiteboard_operations` with
composite tenant foreign keys. Older application images ignore those tables,
so application roll-forward or rollback does not reinterpret existing rows.
Direct down migrations remain prohibited. Capacity, row growth, replay latency,
WebSocket fan-out, and rejected payloads must be monitored before increasing
the reviewed limits.

### Security and privacy consequences

Server validation rejects unsupported element types, links, custom data,
oversized scenes, invalid identities, and unauthorized access. Realtime
presence exposes only user identity, bounded pointer position, button state,
and bounded selected-element IDs to current members. No scene content enters
ordinary telemetry or LiveKit.

## Validation

- Core tests cover durable append/replay/clear, exact idempotency conflicts,
  stale-generation rejection after clear, unsafe payload rejection, membership
  denial, and concurrent gap-free sequencing.
- Web tests cover REST status and presentation, channel join, bounded presence,
  post-join revocation, and outbound reauthorization.
- Client tests cover deterministic projection, equal-version conflict
  resolution, revision tracking, navigation, lint, types, all unit suites, and
  the production build.
- Browser qualification covers two concurrent human sessions, reconnect,
  persistence after reload, clear-for-everyone, keyboard use, and narrow-screen
  layout against the exact packaged candidate.
- Architecture, OpenAPI, AsyncAPI, documentation, dependency, migration,
  regression, and same-digest staging/production gates remain mandatory.

## Revisit triggers

- Boards approach the operation, replay-latency, storage, or fan-out budget.
- Images, embeds, export, guest access, instant rooms, or service automation are
  requested.
- Independent scale or fault isolation justifies a new runtime owner.
- Excalidraw licensing, security, React compatibility, or maintenance changes.
