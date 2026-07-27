# Runbook: Instant-room degradation

- **Owner:** K-Comms application, identity, security, and platform operations
- **Alerts/triggers:** elevated instant-room create/preview/join failures,
  shared abuse-store errors, lifecycle or reconciler backlog, overdue leases,
  participant-capacity errors, conversion failures, or synthetic join failure
- **Default severity:** Sev-2 for bounded public-surface degradation; Sev-1 for
  workspace authority widening, cross-tenant admission, secret exposure,
  sustained unauthorized access after expiry, or uncontrolled public creation
- **Dashboard:** service overview, `lifecycle` queue, configured-public-tenant
  aggregate, shared rate-limit/challenge provider, and media-provider views
- **Required context:** environment, immutable release revision, image digest,
  feature-flag state, configured tenant slug fingerprint, edge/worker replica
  count, affected operation, and first/last observed time

## User impact

Public users may be unable to create, preview, join, reconnect to, or convert an
instant room. Existing room participants may lose realtime presence, messaging,
or media admission if lifecycle or provider authority is unhealthy. Normal
authenticated workspace communication should remain available; treat impact to
that surface as a wider service incident and follow the service-degradation
runbook in parallel.

## Preconditions and safety warnings

Instant rooms are an optional public surface. Normal authenticated workspace
communication is more important than preserving anonymous create or join.
Disable the public feature or let it fail closed when tenant resolution,
distributed abuse enforcement, lifecycle authority, verification, or privacy
controls are uncertain.

Never:

- enable production because the code path or `/api/v1/status` field exists;
- let request data, Host, token claims, or browser state choose the public
  tenant;
- bypass same-origin JSON, authentication rejection, quotas, rate limits,
  challenge policy, retention, audit, or lifecycle deadlines;
- substitute per-node counters for the shared abuse authority;
- extend a guest or room deadline manually;
- print link tokens, idempotency keys, connection identifiers, email, client
  IPs, room membership, messages, call tokens, or media-room identifiers; or
- describe a self-service email as verified until the approved provider
  completed verification.

## Initial diagnosis

1. Confirm the exact release, image digest, migration level, application and
   worker convergence, and current flag:

   ```bash
   : "${NAMESPACE:?set the namespace}"
   : "${API_ORIGIN:?set the trusted origin}"
   kubectl -n "$NAMESPACE" get deployment k-comms-edge k-comms-worker -o wide
   kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=30s
   kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=30s
   curl --fail --silent --show-error "$API_ORIGIN/api/v1/status"
   ```

2. Verify through approved secret/config inventory, not logs, that
   `INSTANT_ROOMS_ENABLED` is expected for this environment and
   `INSTANT_ROOM_TENANT_SLUG` resolves to exactly one active, deliberately
   provisioned tenant. A missing or ambiguous tenant must report the capability
   unavailable.
3. Compare failures across create, preview, join, guest authentication,
   presence, message, call, and optional conversion. Use synthetic rooms and
   identities only.
4. Inspect content-free aggregate state:

   - shared rate-limit/challenge availability, latency, denials, and key-space
     saturation;
   - active/idle/expired room counts, lease age bands, stale generation no-op
     counts, and participant-limit rejections;
   - `lifecycle` queue available/running/retryable/discarded counts, oldest due
     age, and reconciler batch duration;
   - database lock/transaction latency, pool saturation, replication lag, and
     tenant admission-capacity results; and
   - media readiness and participant-eviction backlog.

5. A 30-second server-side channel renewal, 90-second lease, 90-second
   reconnect grace, 3,600-second guest-owner idle period, 86,400-second
   registered-owner idle period, and participant limit of 25 are the production
   contract. There is no client or HTTP heartbeat command. Do not adjust these
   values during incident diagnosis.

## Stabilization actions

1. Freeze rollout expansion and preserve content-free evidence.
2. If cross-tenant selection, authority widening, token leakage, shared abuse
   enforcement failure, or deadline bypass is plausible, set
   `INSTANT_ROOMS_ENABLED=false` through reviewed configuration and roll edge
   pods safely. Confirm status reports `instant_rooms: false`.
3. Keep worker processing enabled unless the worker itself is corrupting
   lifecycle state. Feature disablement stops new public work; lifecycle and
   revocation must continue for existing rooms.
4. If the shared abuse or challenge provider is unavailable, keep create and
   join failed closed. Do not fall back to process-local counters. Signed-in
   workspace traffic should remain available.
5. If the lifecycle queue is delayed, restore worker capacity and dependency
   health. Server authorization must still reject an expired room even before
   cleanup. Let generation-fenced jobs snooze or no-op normally; do not edit
   deadlines or mark jobs complete.
6. If Presence is degraded, keep durable leases authoritative. Do not infer
   occupancy solely from a channel process or client report.
7. If media is degraded, preserve instant-room text where authorization is
   healthy and follow the service-degradation media procedure. Expiry and
   membership revocation must still commit and enqueue provider eviction.
8. If self-service conversion or email handling is uncertain, set
   `INSTANT_ROOMS_ENABLED=false` and keep the whole public surface closed until
   a separate default-off conversion gate exists and is qualified. The
   response capability is not an operator switch. Do not assert verification
   or widen the identity to workspace scope.

## Stop conditions

Stop mitigation and preserve the current immutable release evidence when the
release revision, tenant configuration, shared abuse authority, schema
compatibility, or rollback compatibility cannot be proved. Do not continue a
rollout, change a lifecycle deadline, bypass a failed dependency, or apply an
older application release while any of those facts remain uncertain.

Stop the public rollout immediately if cross-tenant selection, workspace
authority widening, raw secret exposure, sustained authorization after expiry,
or uncontrolled public creation remains plausible after containment.

## Escalation

Escalate immediately to incident command and Security/Privacy for cross-tenant
admission, workspace authorization from a conversation-only account, raw
secret/identifier exposure, unverified-email recovery, sustained access after
expiry, or uncontrolled anonymous creation. Escalate to the Conversations,
IdentityAccess, Web, Workers, and platform owners when shared rate limiting,
configured-tenant resolution, lifecycle convergence, or media eviction cannot
be restored with the bounded actions in this runbook.

## Recovery validation

Use two or more edge replicas and synthetic users:

1. Confirm feature-off and malformed/missing-tenant configurations fail closed
   and do not affect normal workspace sign-in, messaging, or calls.
2. Confirm anonymous create requires same-origin JSON and one exact
   43-character Base64URL idempotency key. Within ten minutes, an exact replay
   returns a usable response with `replayed: true`; create reissues the same
   join token from its AES-GCM replay capsule and guest create/join resumes the
   same identity/admission with a newly bounded session. A changed fingerprint
   returns `idempotency_conflict`. Confirm no capsule plaintext is stored and
   its nonce, tag, key id, expiry, and tenant/room/version AAD are valid. After
   expiry, confirm the bounded reconciler erases ciphertext/nonce/tag/key id,
   retains only the non-secret room conflict tombstone, keeps human join
   receipts for the twenty-four-hour post-expiry tombstone period, and prunes
   them afterward.
3. Confirm preview and join return one indistinguishable unavailable result for
   malformed, unknown, exhausted, revoked, and expired tokens.
4. Confirm the URL fragment is removed before another request and raw tokens,
   application connection/session identifiers, idempotency values, email, and
   IP are absent from responses other than the fresh or authorized exact-replay
   secret response, logs, telemetry, audit, outbox, Presence, and error
   capture. Opaque Phoenix `phx_ref` transport fields are handled only as
   described below.
5. Confirm presence state/diffs are keyed by `user_id` and K-Comms application
   metadata contains only `account_type` and `online_at`. Phoenix may add only
   opaque `phx_ref`/`phx_ref_prev` transport references; confirm clients and
   telemetry do not interpret, persist, or log them as domain identifiers.
   Exercise server renewal loss, reconnect before and after grace, duplicate
   connections, replica termination, and partition recovery.
6. Confirm concurrent participant 25/26 admission, tenant quotas, active-user
   quotas, and call admission are atomic and fail without partial identities,
   memberships, sessions, leases, or jobs.
7. Confirm guest-owner expiry at one hour and registered-owner expiry at
   twenty-four hours with clock-controlled fixtures. Stop/restart workers,
   advance generations, and prove stale jobs no-op, moved deadlines snooze,
   reconciler batches remain bounded, and eventual expiry revokes REST,
   WebSocket, and media access.
8. Confirm optional conversion preserves the user and conversation while
   keeping `access_scope=conversation_only`; directory, discovery, unrelated
   conversation, creation, admin, operations, and service routes remain
   forbidden. Confirm no verified-email claim or recovery path exists before
   provider verification.
9. Confirm expired-room messages, call history, audit, moderation, and legal
   hold follow owner retention rather than being deleted by lifecycle workers.

## Rollback and removal of temporary controls

Turning the feature off is the preferred containment action. Application
rollback is allowed only after public writers are quiesced and the target
release declares support for `users.access_scope`, ephemeral-room tables,
guest-link purpose values, and lifecycle/reconciler jobs. If any incompatible
row or active job exists, use a guest/instant-room-compatible bridge or roll
forward. Do not run schema down migrations or rewrite a conversation-only
identity as workspace-scoped.

Remove temporary capacity, routing, or feature controls only after recovery
validation succeeds on the immutable release revision and the incident
commander approves the change. Record each removal and repeat the affected
synthetic create/join/reconnect/expiry check.

## Evidence to capture

Retain the release/config identity, status capability, synthetic results,
content-free room/lease/queue/rate-limit aggregates, every approved change,
recovery timing, and rollback decision. Exclude raw secrets, email, IP,
connection/session/device identifiers, message/member lists, and media
identifiers.

## Follow-up

After recovery, update capacity, alerts, abuse policy, privacy and retention
review, provider qualification, tests, and this runbook before production
enablement can be re-approved. Attach the immutable release revision, approved
configuration fingerprint, recovery timings, and action owners to the incident
record without copying restricted identifiers or communication content.
