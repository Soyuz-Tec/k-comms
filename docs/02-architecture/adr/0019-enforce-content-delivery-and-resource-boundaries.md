# ADR-0019: Enforce content, delivery, and resource boundaries

**Status:** Accepted

## Context

Completion review found several controls that were individually present but
not enforced at the narrowest shared boundary. Conversation moderators could
reach owner transitions; archived conversations remained searchable; direct
message deletion did not share the legal-hold policy. A claimed webhook could
outlive an endpoint change, outbound response reads reused a per-read timeout,
and transient notification transport failures became terminal. Anonymous
service/socket authentication and password verification also performed bounded
but expensive work before sufficiently specific admission controls. Browser
push registration had no durable fanout ceiling.

These are cross-cutting security and availability decisions, not controller or
client presentation details.

## Decision

### Authority and retained content

- Only a current conversation owner may assign owner or act on an owner.
  Existing tenant-owner/admin authority over tenant-visible channels remains.
  Moderators may manage ordinary memberships but cannot promote themselves,
  assign owner, or demote/remove an owner. Same-role member addition is
  idempotent; every role rewrite uses the optimistic-versioned change path.
- Human and service search exclude archived conversations through their
  authoritative database query. Direct author deletion acquires the governance
  serialization lock before the message lock and refuses deletion while an
  applicable tenant, conversation, or sender legal hold is active.
- Conversation metadata events use the same per-event authorization check as
  messages and membership events, so a joined socket does not retain authority
  after archival, membership loss, or session revocation.

### External delivery

- Webhook claim, materialization, endpoint mutation, and secret rotation use
  endpoint-then-delivery lock order. URL changes, disable, and secret rotation
  return a conflict while a current delivery claim is in progress. A successful
  change therefore cannot overtake an older request without holding a database
  transaction across provider I/O. Stale claims are bounded at 300 seconds;
  configured provider HTTP deadlines are capped at 120 seconds.
- The pinned HTTPS transport uses one monotonic deadline across DNS-resolved
  addresses, connect, send, and every response receive. DNS/connect/TLS/send/
  receive/timeout failures remain retryable; invalid configuration, policy
  failures, and permanent HTTP responses are terminal.
- Webhook secret ciphertext remains bound to tenant, endpoint, version, and key
  identifier. The context-free `legacy` key identifier is rejected in runtime
  and schema. An upgrade aborts until affected endpoints are rotated by the
  prior release and every legacy delivery claim has drained. Operators quiesce
  and terminate the prior worker before clearing an abandoned claim; claim age
  cannot prove that the older transport stopped. The migration locks the
  affected tables against concurrent writers, then removes the retired
  ciphertext and terminally marks its other outstanding deliveries while
  preserving delivered history and rotation audit evidence.

### Admission and fanout

- Service APIs apply a 600-request/minute peer-IP admission bucket before any
  credential database lookup and retain the authenticated identity bucket.
- Password change and step-up use separate 20-request/minute peer-IP and
  five-request/minute user buckets before password-verifier work.
- Socket handshakes use a 60-connection/minute client-IP bucket before consuming
  a one-time ticket. Forwarded addresses are accepted only from configured
  trusted proxy networks using the same right-most-untrusted rule as HTTP.
  Production ingress applies matching path-level admission to service,
  password-verification, and socket routes.
- Active browser-push subscriptions are capped transactionally at five per
  device and ten per user under a user-scoped PostgreSQL advisory lock. Fanout
  reads are independently bounded at ten. Deleting a subscription may retain
  its positive version on the historical notification intent after the foreign
  key is cleared.

## Consequences

- Legitimate owners and tenant administrators retain supported ownership
  workflows, while a moderator compromise cannot acquire durable ownership.
- Operators may receive HTTP conflict while changing a webhook with an active
  delivery and must retry after that bounded delivery completes. This makes the
  no-stale-destination guarantee explicit without consuming a database
  connection for the duration of provider I/O.
- Password, service, and socket abuse consumes bounded node work. Ingress and
  globally distributed limits still require provider-specific calibration;
  the application buckets are node-local backstops.
- A device or user at push capacity must revoke or let a subscription expire
  before registering another. Existing delivery evidence remains internally
  consistent if a subscription is later physically removed.
- Databases containing context-free webhook ciphertext require an audited
  pre-upgrade secret rotation rather than a compatibility decryption bypass.

## Alternatives considered

- **Rely on controller or UI role checks:** rejected because domain callers,
  workers, services, and sockets share the same security invariants.
- **Cancel a delivery after the provider request:** rejected because it cannot
  retract disclosed data. Successful endpoint mutation instead waits for the
  application-visible in-flight boundary by returning conflict.
- **Hold endpoint row locks during provider HTTP:** rejected because a slow
  provider could consume the database pool.
- **Give every address/read a fresh timeout:** rejected because slow-drip or
  multi-address destinations could multiply the advertised deadline.
- **Cap push fanout only when reading:** rejected because excess encrypted
  subscriptions would remain durable amplification state.

## Validation

Focused database, controller, channel, worker, transport, rate-limit, migration,
and concurrency tests cover malicious and legitimate ownership transitions,
archived search, legal holds, webhook claim/change races, deadline exhaustion,
retry classification, pre-work admission, proxy spoofing, push over-admission,
historical foreign-key cleanup, and event-time reauthorization. The full
repository and exact-image staging gates remain required for every promoted
revision.
