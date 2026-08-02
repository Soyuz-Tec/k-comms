# ADR-0065: Make instant rooms collaboration workspaces

- **Status:** Accepted
- **Date:** 2026-08-01
- **Owners:** Product, Architecture, Conversations, Collaboration, Web, Security,
  Privacy, and Operations
- **Reviewers:** Release and Quality
- **Related requirements:** FR-COL-001, FR-MSG-001, FR-SYNC-001, ADR-0049,
  ADR-0050, ADR-0063

## Context

The public K-Comms front door currently presents product marketing and then asks
the visitor to create a text/audio/video instant room. Durable Excalidraw
whiteboards exist only for workspace humans. The intended public product is a
working collaboration surface: after one explicit display-name submit, the host
must be able to message and draw in the same room and invite another person with
the existing fragment-bearing link or locally generated QR code.

Automatically creating a durable room on page load would turn crawlers,
previews, and abandoned visits into public writes. Giving every guest link
whiteboard history would also expose pre-admission work from an existing durable
conversation. The expansion must therefore be limited to self-service instant
rooms and preserve their configured tenant, expiry, membership, admission,
abuse, and revocation boundaries.

## Decision

1. `/` becomes an application-first instant-workspace launcher. It shows the
   messaging/canvas product directly and requires one explicit start submission
   before any durable room, identity, message, or whiteboard record is created.
2. An active or idle instant-room conversation exposes one shared durable
   whiteboard to its active host and participants. Workspace humans retain their
   existing member whiteboard access. Conversation-only humans and guests gain
   whiteboard access only when their active membership belongs to a non-expired
   instant room. Ordinary ADR-0049 guest links remain denied.
3. Guest REST access uses only
   `/api/v1/guest/conversation/whiteboard/operations`. The verified guest claim
   supplies the conversation identifier; request path, query, and body values
   cannot select another conversation. The existing member path remains
   unchanged.
4. The dedicated `whiteboard:{conversationId}` Phoenix topic is reused. Guest
   sockets must match the exact admitted conversation and are reauthorized for
   join, inbound presence, and every intercepted outbound event. No new process,
   supervisor, registry, PubSub owner, or message-ordering boundary is added.
5. Joining an instant workspace shares the current complete board scene,
   including operations created before that participant joined. This differs
   deliberately from message history: the instant-room link shares the current
   working canvas, while message visibility retains its immutable admission
   sequence. Ordinary durable-conversation guest links do not receive this
   exception.
6. K-Comms continues to own authorization, canonical sequencing, persistence,
   retry, replay, and projection. The exact Excalidraw adapter, supported element
   set, payload limits, idempotency, clear generation, and disabled images,
   embeds, links, and custom data from ADR-0063 remain unchanged.
7. Guest whiteboard writes consume a cluster-wide
   `instant_room_whiteboard` fixed-window bucket keyed by an HMAC of tenant,
   user, session, and room. The default permits 240 committed batches per minute
   so normal editor batching remains usable while one public identity cannot
   write without bound. Existing board operation and element caps remain the
   durable capacity limit.
8. The public room client composes the existing messaging viewport and reusable
   whiteboard adapter into one desktop split workspace. Mobile presents one
   accessible Canvas/Messages switch. Link copying, system sharing, local QR
   generation, call controls, presence, expiry, conversion, and room continuity
   keep their existing APIs and lifecycle.
9. Room expiry, membership removal, guest logout, revocation, or session expiry
   immediately ends both REST and realtime whiteboard authority. Whiteboard
   records remain Restricted conversation content and follow existing retention,
   governance deletion, backup, and restore rules.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Auto-create a room on every GET `/` | Zero-submit appearance | Public write amplification, abandoned rooms, bot abuse | Durable collaboration requires explicit intent |
| Enable whiteboards for every guest link | One guest implementation | Leaks pre-admission durable conversation scenes | Wider history requires a separate policy |
| Store a browser-only local canvas | No server change | Cannot share, replay, authorize, or reconcile | Does not satisfy a working shared workspace |
| Fork Excalidraw collaboration | Full editor control | Duplicates authorization/persistence and raises maintenance risk | ADR-0063 keeps the editor replaceable |
| Create a separate canvas service | Independent scale | New deployment, data owner, failure modes, and consistency boundary | Current measured need fits the modular monolith |

## Consequences

### Positive

- The public front door becomes the usable product rather than a brochure.
- One invite shares messaging, calls, presence, and the current drawing canvas.
- Existing instant-room expiry and revocation semantics protect the new surface.
- The same member and guest editor adapter preserves deterministic behavior.

### Negative and accepted trade-offs

- The active instant-room route downloads the lazy Excalidraw bundle.
- A later joiner sees the room's current canvas even though earlier messages stay
  outside that guest's history boundary; the UI and tests must preserve this
  intentional distinction.
- Public drawing adds write load and requires its own distributed abuse bucket.

### Operational consequences

- The rate-limit scope constraint expands through a forward migration; no table,
  owner, transaction boundary, or release unit changes.
- Capacity qualification must include concurrent guest scene updates, replay,
  presence, room expiry, and reconnect.
- The existing same-digest staging/production release and rollback/restore gates
  remain mandatory.

### Security and privacy consequences

- No token, QR payload, element text, pointer, message, or raw rate-limit key may
  enter logs, metrics, audit metadata, or URLs outside the existing fragment.
- Server-side active-membership and instant-room checks remain authoritative;
  hiding the canvas in the client is never an authorization control.
- Excalidraw images, external links, embeds, and custom data remain rejected.

## Validation

- Core/web integration tests prove instant-room host and guest append/replay,
  caller-supplied conversation substitution denial, ordinary guest-link denial,
  idempotency, distributed rate limiting, realtime join, and revocation.
- React tests cover guest/member API adapters, lazy canvas loading, desktop split
  layout, mobile Canvas/Messages switching, QR/link sharing, and preserved room
  continuity.
- Two-browser end-to-end qualification proves host creation, QR/link join, live
  message exchange, shared drawing replay, simultaneous edits, reconnect, expiry,
  and access denial after revocation.
- Architecture, OpenAPI, AsyncAPI, migration, formatter, static analysis, full
  regression, exact-image staging, rollback/restore, and production health gates
  remain required.

## Revisit triggers

- Ordinary durable-conversation guests require scoped board history.
- Images, embeds, exports, service automation, or offline merge semantics expand.
- Public write volume exceeds the operation, latency, storage, or abuse budget.
- Independent collaboration scaling or fault isolation becomes measurable.
