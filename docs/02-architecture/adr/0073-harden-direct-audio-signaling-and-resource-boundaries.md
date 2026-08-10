# ADR-0073: Harden direct-audio signaling and resource boundaries

- **Status:** Accepted
- **Date:** 2026-08-09
- **Owners:** Media, Web, Security
- **Reviewers:** Architecture, Security, Release and Quality
- **Related requirements:** FR-COM-001, NFR-SEC-001, NFR-PERF-001, NFR-REL-001, ADR-0002, ADR-0003, ADR-0025, ADR-0072

## Context

ADR-0072 introduced an authorized, opt-in, one-to-one audio transport with
LiveKit fallback. A security review identified six resource and lifecycle gaps:
client signals could accumulate after fallback, Presence projection work could
grow with duplicate clients, asynchronous microphone replacement could retain
a track after teardown, SDP bounds did not prove audio-only grammar, the
signaling quota was node- and session-local, and the WebSocket transport
accepted messages substantially larger than the protocol needed.

The correction must retain the consent model and no-new-paid-service constraint.
It must work across multiple edge replicas and must not turn ephemeral SDP or
ICE into durable call history.

## Decision

1. A direct call has a server-enforced signaling state machine: ready, offer
   sent or received, connected, and disabled. Only the lexicographically lower
   random peer ID may offer. Answers, ICE, media state, and fallback are valid
   only for the selected peer and the expected state.
2. Presence projects at most one connection per user and two direct peers per
   call. A duplicate connection is disabled and untracked server-side. Client
   fallback explicitly disables and untracks its direct Presence entry.
3. Direct join, message-count, and byte-cost quotas use PostgreSQL atomic
   fixed-window buckets keyed by HMAC digests of bounded tenant, actor, call,
   and target identifiers. Session identity is intentionally omitted so new
   sessions or a different edge replica cannot reset the actor budget. The
   existing node-local limiter remains a fast defense-in-depth control.
4. Offer and answer SDP must contain exactly one `m=audio` media section,
   begin with `v=0`, remain within 16 KiB, and contain neither SCTP attributes
   nor NUL data. The browser applies the same policy and fails closed on a
   data channel or non-audio remote track.
5. The browser queues at most 32 pre-transport signals, 64 KiB total, for no
   more than 15 seconds. Pending ICE is capped at 64 candidates. Fallback is a
   terminal state for that call attempt, clears both queues, and restores the
   already-connected LiveKit microphone even if no direct transport object was
   created.
6. Microphone acquisition and replacement are generation-bound. Every track
   that is not committed to the current live peer connection is stopped in a
   `finally` path, including teardown and replacement-failure races.
7. Phoenix and Bandit both cap a complete or fragmented WebSocket message at
   1 MiB. Smaller event-level bounds continue to apply after decoding.

PostgreSQL, Phoenix Presence, and the existing LiveKit connection provide all
controls. This decision adds no hosted service, subscription, credential, or
relay cost.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Decision |
|---|---|---|---|
| Add Redis for distributed quotas | Familiar high-rate counter primitive | Adds a paid or operated stateful dependency for a low-volume pilot | Rejected for now |
| Keep per-node counters and tighten values | Small code change | Sessions and replicas still multiply the effective budget | Rejected |
| Disable direct audio | Removes the reviewed path | Loses the requested feature instead of correcting bounded risks | Rejected |
| Persist signaling state and SDP | Easier forensic reconstruction | Creates sensitive durable data without a product requirement | Rejected |

## Consequences

### Positive

- Direct signaling has replica-independent admission and deterministic
  lifecycle limits.
- Fallback and teardown release memory, Presence, peer connections, and media
  tracks predictably.
- The architecture still has no new financial dependency.

### Negative and accepted trade-offs

- Each direct join and signal performs one or two small PostgreSQL counter
  writes, which must be included in capacity tests.
- The one-active-connection-per-user policy can reject a second tab or device
  until Presence convergence removes the first.
- Strict audio-only SDP can reject a future browser negotiation shape; any
  broader grammar requires a reviewed versioned protocol change.

## Validation

- Database tests prove weighted atomic counters and aggregation across session
  identifiers.
- Channel tests prove deterministic negotiation order, audio-only SDP,
  duplicate-client denial, fallback terminalization, and target isolation.
- Client tests prove count/byte/age queue bounds, ICE bounds, teardown races,
  replacement failure cleanup, and rejection of video, application, data
  channel, and non-audio-track input.
- Configuration tests prove matching Phoenix and Bandit 1 MiB limits.
- The normal immutable staging and same-digest production promotion remains
  required; physical endpoint media qualification remains a separate gate.

## Revisit triggers

- PostgreSQL counter write load becomes material at measured call volume.
- Multi-device direct calling becomes a product requirement.
- Direct TURN or direct-video transport is authorized.
- Browser SDP output requires a broader, explicitly reviewed audio grammar.
