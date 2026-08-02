# ADR-0066: Allow local-first instant workspace drafts

- **Status:** Accepted
- **Date:** 2026-08-01
- **Owners:** Product, Architecture, Collaboration, Web, Security, Privacy, and
  Operations
- **Reviewers:** Release and Quality
- **Related requirements:** FR-COL-001, FR-MSG-001, FR-SYNC-001, ADR-0050,
  ADR-0063, ADR-0065

## Context

ADR-0065 made `/` an application-first instant-workspace launcher but retained
an explicit start form before the editor. That prevents crawlers and abandoned
page views from creating durable rooms, but it still places configuration ahead
of the main user task. A first-time visitor should be able to draw immediately,
without creating server state, while retaining a safe path into the existing
durable collaboration model.

The browser-only-canvas alternative rejected by ADR-0065 remains unsuitable as
the collaboration authority. A local draft is acceptable only as a temporary
pre-room state that is promoted through the existing authenticated or guest
room contracts before it is shared.

## Decision

1. `/` opens directly into a private Excalidraw draft with an adjacent message
   surface. Loading the page does not create a tenant, identity, conversation,
   message, whiteboard operation, socket subscription, or audit record.
2. The client generates an editable guest display name and stable draft,
   message, and whiteboard operation identifiers. Authenticated identities
   remain server-managed and cannot be changed in the draft.
3. The draft scene and minimal launcher metadata are stored only in browser
   local storage. The UI labels the draft as private and device-local. Drafts
   are not synchronized, backed up, audited, retained, or recoverable by
   K-Comms before promotion.
4. Sending the first message, selecting Share, or explicitly starting the room
   is the promotion boundary. Promotion creates exactly one instant room using
   the existing idempotency contract, then appends the draft scene and optional
   first message using their stable client identifiers.
5. A failed promotion keeps the local draft and identifiers so the visitor can
   retry without duplicating the room, message, or whiteboard operation. The
   draft is cleared only after all required promotion writes succeed.
6. Once promoted, PostgreSQL, Phoenix Channels, authorization, ordering,
   retention, revocation, rate limiting, backup, and restore remain the sole
   shared-workspace authority defined by ADR-0065. Local storage is never read
   by the server and never overrides durable state.
7. Mobile presents a Canvas/Messages switch; desktop presents both surfaces.
   The default mobile surface is the canvas. Required identity fields remain
   reachable before any promoting action and receive focus on validation
   failure.
8. External links, embeds, images, and custom Excalidraw data remain disabled at
   this boundary. Existing server validation is unchanged and authoritative.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Keep the start form before the editor | Simplest lifecycle | Delays the main task and resembles registration | Does not meet the immediate-use product goal |
| Create a durable room on every page load | Seamless shared state | Bot writes, abandoned rooms, quota and audit noise | Violates explicit-intent and abuse boundaries |
| Keep all collaboration browser-only | No server write path | No authorization, sharing, replay, ordering, or recovery | Conflicts with ADR-0065 and durable collaboration requirements |
| Introduce a separate draft service | Cross-device drafts | New data owner, privacy scope, deployment unit, and failure modes | No measured need for server-side pre-room drafts |

## Consequences

### Positive

- A visitor can draw immediately while passive visits remain read-only to the
  platform.
- Refresh-safe drafts reduce accidental work loss before sharing.
- Stable identifiers preserve existing retry and ordering guarantees during
  promotion.
- Shared collaboration continues to use one server-authoritative model.

### Negative and accepted trade-offs

- Pre-promotion work is device-local and can be lost when storage is cleared or
  unavailable.
- Local storage contains draft drawing content and must be described accurately
  in privacy guidance and cleared on shared devices when needed.
- Promotion is a short multi-write workflow. Partial failure must remain
  retryable and idempotent rather than pretending to be atomic.

### Operational consequences

- No schema, supervisor, process ownership, deployment topology, or server
  transaction boundary changes.
- Browser acceptance must prove zero room writes on load and exactly one room
  write on promotion across supported desktop and mobile sizes.
- Release qualification must cover scene/message carry-over, retry, refresh
  restoration, accessibility, and the existing instant-room lifecycle.

### Security and privacy consequences

- Draft content remains in the browser profile until successful promotion, a
  new draft, or user-controlled site-data removal. It must never enter logs or
  telemetry.
- Only a successful server-authorized promotion makes content visible to other
  participants.
- Generated identities are presentation defaults, not authentication or proof
  of identity.

## Validation

- Component tests cover immediate canvas availability, generated and managed
  identities, refresh restoration, empty-name guidance, and stable promotion
  identifiers.
- Browser tests cover zero writes on load, exact-once promotion, responsive
  Canvas/Messages access, text reflow, minimum targets, and automated WCAG A/AA
  checks.
- Existing instant-room, messaging, whiteboard, guest authorization, retry,
  continuity, and protected release suites remain mandatory.

## Revisit triggers

- Cross-device or account-bound draft synchronization is required.
- Local draft encryption, explicit export, or retention controls become a
  product requirement.
- Promotion needs a server-side transactional aggregate instead of idempotent
  sequential writes.
- Image or embed support is approved for public drafts.
