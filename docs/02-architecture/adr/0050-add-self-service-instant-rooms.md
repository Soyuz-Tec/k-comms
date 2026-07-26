# ADR-0050: Add self-service instant rooms

- **Status:** Accepted
- **Production enablement:** Gated until the prerequisites in this decision
  are implemented, qualified, and approved
- **Date:** 2026-07-24
- **Owners:** Architecture, Conversations, IdentityAccess, ConversationContent,
  Calls, Web, Workers, Security, Privacy, and Operations
- **Related decisions:** ADR-0001, ADR-0004, ADR-0017, ADR-0018, ADR-0025,
  ADR-0033, ADR-0034, ADR-0035, ADR-0043, ADR-0046, ADR-0049

## Context

K-Comms needs a no-onboarding path in which a person can create a temporary
communication room, copy its unique link or display its QR code, and begin
text, audio, or video communication. A recipient must be able to preview and
join with a display name. Either participant may remain a guest; creating an
account is optional.

ADR-0049 provides host-created guest links for an existing durable
conversation. An instant room has a different entry point and lifecycle: it
may be created without a signed-in workspace member, it always belongs to one
configured public tenant selected by trusted server configuration, and it
expires from authoritative idle and presence state. It must not become an
anonymous workspace-registration endpoint or a source of unbounded identities,
rooms, jobs, sessions, media allocations, or retained content.

The first implementation can accept an email and password when an instant-room
guest elects to create an account, but it does not verify control of that
email. Production must therefore keep instant rooms disabled until an approved
email-verification provider and workflow, distributed abuse controls, privacy
review, and operating evidence are present.

## Decision

Keep instant rooms inside the existing modular monolith, release, PostgreSQL
database, and media-plane boundary.

The delivery branch accumulates the accepted ADR-0046 mobile projections and
ADR-0049 guest-access boundary changes on the protected base. Its one-time
reviewed manifest transition therefore declares that exact cumulative delta
alongside this decision's instant-room changes. It grants no authority beyond
those accepted decisions and must be removed after the cumulative declaration
lands on the protected branch.

### Ownership and transaction boundaries

1. Conversations owns the instant-room aggregate, lifecycle generation,
   participant limit, guest-link purpose, presence leases, bounded join-replay
   receipts, activity deadline, durable lifecycle scheduling, reconciliation,
   and conversation membership. It owns `conversation_ephemeral_rooms` through
   `CommsCore.Conversations.EphemeralRoom` and
   `conversation_ephemeral_presence_leases` through
   `CommsCore.Conversations.EphemeralPresenceLease`; exact-key join replay uses
   `conversation_ephemeral_join_receipts` through
   `CommsCore.Conversations.EphemeralJoinReceipt`.
2. IdentityAccess owns guest and human identities, devices, sessions,
   authentication, `users.access_scope`, bounded guest-authority extension,
   and guest-to-human conversion. It does not own room or presence state.
3. ConversationContent continues to own messages and Calls continues to own
   audio/video lifecycle and provider admission. An instant room creates no
   alternate message, attachment, call, or media store.
4. Anonymous creation and join are Conversations-owned transactions. They lock
   tenant admission state, create or reuse the exact conversation and
   membership, call IdentityAccess only through its existing facade within the
   transaction, create the room/link/admission/lease and unique lifecycle job,
   append token-free audit/outbox evidence, and commit or roll back together.
5. `CommsWorkers.EphemeralRoomLifecycleWorker` calls only
   `CommsCore.Conversations.expire_ephemeral_room/3` for one scheduled room
   generation. `CommsWorkers.EphemeralRoomReconcilerWorker` calls only
   `CommsCore.Conversations.reconcile_ephemeral_room/3` and
   `reconcile_ephemeral_rooms/1`. These are ordinary adapter dependencies on
   the published Conversations business facade; workers never import the room
   or lease Ecto schemas and never access `CommsCore.Repo`.

### Configured public tenant and feature gate

1. Generic runtime configuration and the production overlay keep
   `INSTANT_ROOMS_ENABLED=false` unless the full enablement gate below is
   approved. The loopback-only local release may enable it directly. Portable
   staging remains disabled until an environment-specific composition supplies
   exact narrow trusted-proxy networks and an identical edge-ingress
   NetworkPolicy source set; that controlled composition may then enable it
   solely for qualification with development adapters and a deliberately
   provisioned public test tenant. Those qualification settings are not a
   production precedent.
2. When enabled, `INSTANT_ROOM_TENANT_SLUG` must identify one active,
   deliberately provisioned public tenant. Request data, link data, host
   headers, bearer claims, and browser storage can never choose or override
   that tenant.
3. Missing, blank, malformed, inactive, suspended, or ambiguous tenant
   configuration fails closed. `/api/v1/status` reports `instant_rooms: false`;
   create, preview, and join disclose no tenant lookup detail.
4. Production enablement additionally requires:

   - a qualified email-verification provider and verified-email conversion
     workflow;
   - shared, distributed rate-limit and abuse state across every edge replica;
   - approved bot/challenge policy, moderation and report handling, privacy
     notice, retention configuration, dashboards, alerts, capacity evidence,
     and incident rehearsal; and
   - explicit product, Security, Privacy, Operations, and Release approval for
     the configured public tenant.

The implementation flag is not evidence that these production requirements
have been met.

### Public create, preview, and join

1. `POST /api/v1/instant-rooms` accepts either no Authorization header or one
   valid human bearer credential. Invalid, guest, service, duplicate, or
   malformed Authorization values fail rather than degrading to anonymous.
2. Every public create, preview, and join request requires
   `application/json` and exactly one configured trusted `Origin`. Browsers
   supply it through the same-origin boundary; non-browser qualification tools
   must also send the exact value for uniform enforcement. The header is a CSRF
   boundary, not authentication or tenant selection. Form posts, missing or
   duplicate Origin values, and untrusted origins fail.
3. Creation requires an exact 43-character unpadded Base64URL
   `Idempotency-Key` carrying 256 random bits. The stored key and request
   fingerprint are SHA-256 digests. For ten minutes, a first success also
   retains an AES-GCM replay capsule containing the minimum secret response,
   with nonce, tag, key identifier, and AAD bound to tenant, room, and version.
   The same key and fingerprint decrypt and reissue a usable response with
   `replayed: true`; a changed request under the same key returns
   `idempotency_conflict`. Capsule plaintext is never persisted.
4. A first successful anonymous creation returns a scoped guest session and
   the raw 256-bit join token/share URL once. A human already belonging to the
   configured public tenant becomes the registered owner whether its access
   scope is `workspace` or `conversation_only`; the latter gains authority only
   to the newly created instant room, not to workspace capabilities. A valid
   human from another tenant cannot use the bearer to move the room or widen
   cross-tenant authority; the adapter instead creates a distinct
   conversation-only guest in the configured public tenant using trusted
   current profile/device defaults and returns that scoped guest session. This
   fallback creates no cross-tenant identity link or authority widening. Only
   the token digest is stored. The browser locally renders the QR from the
   exact share URL.
5. `POST /api/v1/instant-rooms/preview` accepts the token in a JSON body and
   returns only display-safe room metadata. `POST
   /api/v1/instant-room-sessions` accepts the token, display name, device
   metadata, and an idempotency key. It either admits a new scoped guest,
   attaches a same-tenant human with `workspace` or `conversation_only` scope,
   or uses the distinct conversation-only guest fallback for a cross-tenant
   human bearer. Exact guest join replay resumes the same identity and
   admission and returns a freshly bounded session instead of creating another
   user or membership; authenticated same-tenant human replay reuses the same
   identity and membership. A changed request under the same key conflicts.
6. The raw token stays in `/join#guest=...`, is removed from browser history
   before any other request, and is never placed in a path, query string, log,
   audit event, outbox event, presence payload, telemetry attribute, exception,
   or notification.
7. Unknown, malformed, expired, exhausted, revoked, and non-public-room tokens
   produce one `instant_room_unavailable` response. Preview never reveals the
   configured tenant identifier or internal lifecycle generation.

### Identity and account scope

1. Every instant-room guest is a durable `account_type = guest`,
   `access_scope = conversation_only` identity with a scoped guest session.
2. Optional self-service account creation through the existing guest-account
   endpoint changes the same identity to `account_type = human`, preserves
   `access_scope = conversation_only`, keeps the same user, membership, message
   authorship, call history, and audit attribution, and rotates the guest
   credential into a new human session.
3. A conversation-only human can authenticate and use only conversations to
   which it has active membership plus exact token-authorized instant-room
   create/join operations. It cannot use tenant directory, public-channel
   discovery, standard workspace conversation creation, invitations, tenant
   administration, operations, service credentials, workspace search, or
   another conversation merely because it has a human bearer token.
4. Self-service conversion does not assert or persist a verified-email claim.
   Until the production verification workflow exists, the email is an
   unverified login identifier and instant rooms remain production-disabled.
   Password recovery and security notifications must not treat it as verified.
5. Workspace enrollment is a separate authenticated invitation or
   administrator workflow. It must explicitly widen `access_scope` after
   identity proof and conflict handling; instant-room conversion never does so.

### Presence leases and lifecycle

1. Phoenix Presence remains ephemeral acceleration state. Durable
   `conversation_ephemeral_presence_leases` are the authoritative bounded
   liveness contribution used by lifecycle decisions.
2. Each authorized conversation-channel process renews its durable presence
   lease server-side every 30 seconds while rechecking room and admission
   authority; there is no client or HTTP heartbeat command. A lease lasts 90
   seconds and the reconnect grace is also 90 seconds. A stored connection
   identifier is a SHA-256 digest and is never exposed in REST, channel events,
   audit, or telemetry.
3. An authorized channel open or server-driven heartbeat creates or renews an
   active durable lease and advances `last_presence_at` under a row lock. A
   successful reconnect reactivates an idle room under a generation fence and
   records the server reactivation time as the new reconnect baseline, so a
   global reconciliation pass cannot immediately re-idle the room before its
   channel opens. Message, typing, read-cursor, and call commands do not
   independently extend the room lifetime; per-node process state cannot keep
   a room alive.
4. A room owned by a guest becomes due after 3,600 seconds of authoritative
   inactivity. A room owned by a registered human becomes due after 86,400
   seconds. Conversion upgrades the owner kind and deadline without changing
   the room or conversation identifiers. If conversion happens while the room
   is idle, the registered deadline remains anchored to the authoritative idle
   start and the room, share link, and active admissions move together.
5. The lifecycle worker is unique per room generation. It locks the room and
   leases, snoozes when the generation is current but the deadline moved, and
   is a no-op when stale or terminal. The minute reconciler scans a bounded,
   ordered batch and schedules missing work; it does not perform unbounded
   cleanup in one job.
6. Expiry commits the room terminal state, ends active instant admissions and
   memberships, revokes guest sessions and call authority, schedules provider
   eviction, and publishes token-free lifecycle evidence. Worker or provider
   delay never extends authorization beyond the server-evaluated deadline.
7. Realtime presence is keyed by `user_id`; K-Comms-controlled metadata contains
   only `account_type` and `online_at`. Phoenix Presence may add opaque
   `phx_ref` and `phx_ref_prev` transport references needed for correct diff
   reconciliation. Clients must not interpret, persist, or log those references
   as domain connection identifiers. Device, application connection/session,
   token, IP, email, lifecycle generation, and configured-public-tenant details
   are forbidden.
8. Room lifecycle changes produce durable, token-free Audit and transactional
   Outbox evidence. They are not advertised as client conversation-channel
   events; clients reconcile authorized REST state after membership, call, or
   authorization changes instead of treating a socket signal as lifecycle
   authority.

### Distributed abuse and capacity controls

The controlled non-production implementation has shared PostgreSQL-backed
scopes for create, join (with preview sharing the join bucket), account
conversion, and instant-room message send. Server-generated presence renewals
remain bounded by one authorized user/connection lease contract, and call
admission retains the existing authenticated/guest call policy and rate
controls. This is qualification coverage, not evidence of a production-ready
public abuse posture. During active development and controlled pilot
evaluation, every room-creation rate-limit plug is intentionally bypassed for
all users so testing cannot be blocked by retained buckets. Other public
operations keep their existing controls. Production enablement is forbidden
until an approved room-creation abuse-control policy is restored and qualified.

1. Production enforcement uses a shared store or edge service with atomic
   counters. Process-local ETS limits may be used only for an additional
   best-effort local-development layer and are not a production control.
2. Before production enablement, Security must qualify adaptive public abuse
   controls across create, preview, join, session refresh, account conversion,
   server-side presence renewal, message send, and call admission. Add distinct
   shared scopes where the threat model requires them; do not claim the current
   non-production bucket set is sufficient merely because preview shares join
   or presence/calls have existing bounded authorization.
3. Dimensions include trusted client IP, idempotency-key digest, token/link
   digest, identity/session, room, and configured public tenant as applicable.
4. The edge trusts forwarded client addresses only from configured proxies.
   Untrusted forwarding headers cannot select a rate-limit identity.
5. Limits use bounded windows, return `429` with `Retry-After`, avoid link or
   account enumeration, and emit content-free aggregate signals. Raw IPs,
   tokens, emails, messages, and media identifiers do not enter dashboards.
6. Existing active-user, conversation, membership, message, call, and provider
   quotas remain authoritative. Instant rooms add a maximum of 25 active
   participants and cannot bypass global tenant limits.
7. Repeated challenge failure, provider outage, rate-limit-store outage, or
   abuse-signal uncertainty fails public creation and join closed without
   degrading signed-in workspace communication.

### Retention, deletion, and rollback

1. Room expiry revokes authority; it is not content erasure. Messages, audit
   records, call history, moderation evidence, and legal-hold state remain
   owned by their existing contexts and follow the configured public tenant's
   retention policy.
2. Presence leases, join-replay receipts, idempotency digests, and encrypted
   replay capsules are operational metadata. Replay authority ends after ten
   minutes. The bounded minute reconciler then erases create-response
   ciphertext, nonce, tag, and key identifier while retaining the non-secret
   key digest, request fingerprint, and `replay_erased_at` tombstone with room
   evidence so reuse cannot create a second room. Human join receipts remain
   conflict tombstones for twenty-four hours after their replay expiry and are
   then pruned in bounded batches; guest-join digest/fingerprint evidence
   follows the owning admission's retention and cannot authorize replay after
   its expiry. Terminal presence leases are pruned after reconnect grace plus a
   one-hour incident window. Capsule key rotation and erasure must preserve
   bounded replay or fail closed; plaintext and raw keys are never persisted.
   These metadata classes may not contain raw connection identifiers, email,
   IP, message content, or media identifiers.
3. The room/link/admission lifecycle projection is retained long enough to
   explain authorization, abuse, and deletion outcomes, then deleted or
   tombstoned through Governance. Legal hold blocks destructive content
   deletion but does not reactivate room access.
4. Persisted `users.access_scope = conversation_only`, ephemeral-room tables,
   guest-link purpose values, and active lifecycle jobs are rollback hazards
   for releases that predate this ADR. Turning the feature flag off blocks
   create, preview, join, and instant-room account conversion, but existing
   presence/lifecycle convergence continues and the flag does not make legacy
   code safe.
5. Before application rollback, quiesce create/join/conversion/lifecycle
   writers and prove the target release declares the matching instant-room and
   conversation-only identity capabilities. Otherwise retain a compatible
   bridge or roll forward. Direct schema rollback and rewriting identities to
   workspace scope are forbidden.

## Consequences

- A person can create and share a communication room without account
  onboarding, and recipients can join with one display-name submit.
- Optional account creation preserves identity and history while remaining
  conversation-only.
- Durable leases and generation-fenced workers make expiry correct across
  replicas, restarts, reconnects, and delayed jobs.
- The configured public tenant contains public-room policy and data ownership
  without making tenant selection attacker-controlled.
- The wider anonymous surface adds abuse, privacy, capacity, verification, and
  operational responsibilities. Production remains explicitly disabled until
  those dependencies are qualified.

## Alternatives rejected

| Alternative | Reason rejected |
|---|---|
| Reuse tenant invitations | Requires workspace enrollment and grants broader authority than one room. |
| Reuse only ADR-0049 host links | Does not own anonymous creation, idle lifecycle, durable presence, or configured-public-tenant policy. |
| Let the request choose a tenant | Creates a cross-tenant admission and enumeration boundary. |
| Use Phoenix Presence as lifecycle truth | Presence is eventually consistent and disappears on restart or partition. |
| Use only per-node rate limits | Replicas can be sprayed independently and limits reset on restart. |
| Convert a guest directly into a workspace member | Exposes directory and unrelated workspace capabilities without administrator enrollment. |
| Treat submitted email as verified | Enables recovery and notification claims without proof of mailbox control. |
| Delete all content when a room idles | Conflicts with tenant retention, legal hold, moderation, audit, and recovery evidence. |
| Split instant rooms into a microservice | Adds distributed identity, membership, transaction, and data ownership without an independent scaling justification. |

## Validation

- Domain tests cover exact configured-tenant resolution, feature-off behavior,
  digest-only tokens/connection/idempotency keys, replay and fingerprint
  conflict, tenant and participant quotas, concurrent final-slot admission,
  owner upgrade, deadline movement, stale generations, lease races, lifecycle
  expiry, bounded reconciliation, and idempotent retry.
- Identity tests prove conversation-only guest and human grants cannot access
  workspace routes, guest authority cannot exceed 24 hours, conversion keeps
  one user identifier, old guest credentials are revoked, email is not marked
  verified, and legacy rollback hazards are detected.
- Web tests cover optional-human authentication, same-origin JSON, required
  idempotency keys, uniform unavailable responses, `Retry-After`, secret
  redaction, exact join fragment removal, local QR generation, one-submit join,
  and narrow/mobile accessibility.
- Realtime tests cover scoped topic authorization, bounded application
  metadata plus Phoenix transport refs in presence state/diffs, reconnect grace,
  immediate REST/WebSocket denial after expiry, and call eviction. Domain and
  worker tests cover durable Audit/Outbox lifecycle evidence.
- Contract validation pins create, preview, join, status capability,
  idempotency, presence, lifecycle, and mirror parity.
- Staging qualification exercises at least two edge replicas and worker
  replicas with a shared abuse store, browser reconnects, worker interruption,
  rate-limit-store and verification-provider outages, room expiry, retention,
  and rollback preflight.
