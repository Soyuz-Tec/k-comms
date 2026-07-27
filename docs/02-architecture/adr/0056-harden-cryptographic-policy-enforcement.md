# ADR-0056: Harden cryptographic policy enforcement

- **Status:** Accepted
- **Date:** 2026-07-26
- **Owners:** Architecture, Security, Identity, Integrations, and Operations
- **Related decisions:** ADR-0006, ADR-0014, ADR-0018, ADR-0021

## Context

K-Comms intentionally keeps message content server-readable under ADR-0006.
Restricted integration fields use AES-256-GCM, while passwords use
PBKDF2-HMAC-SHA256 and public traffic is expected to terminate through TLS.
An encryption-focused review found that the primitives were generally sound
but several enforcement points could drift: password hashes used an older work
factor, missing login identities skipped password work, URL query parameters
could override database TLS, current key identifiers were not promotion-bound
to their keyrings, key material could be reused across purposes, internal
object-storage HTTP had a broader runtime exception than the production gate,
and webhook rotation did not immediately revoke queued old-key deliveries.

## Decision

1. New password hashes use 600,000 PBKDF2-HMAC-SHA256 iterations. Verified
   legacy hashes are upgraded on successful login, and missing identities pay
   the current derivation cost. Every invalid login response is padded to a
   500-millisecond floor plus bounded 0-to-50-millisecond jitter so accepted
   legacy costs cannot invert the account-existence timing signal during
   migration.
2. `SECRET_KEY_BASE` is rejected at runtime below 64 bytes.
3. `DATABASE_URL` may not contain an `ssl` query parameter. The independently
   configured `DATABASE_SSL` policy, CA bundle, peer verification, SNI, and
   hostname verification remain authoritative.
4. Runtime and deployment validation require the active encryption key ID to
   exist in its keyring, reject duplicate material within a rotation ring, and
   reject webhook/push material reuse.
5. Production edge and worker workloads must use matching
   `k-comms-secrets` references for core credentials and encryption material.
6. Internal object-storage endpoints use the same HTTPS-or-explicit-local-host
   policy as browser-facing object-storage endpoints.
7. Ephemeral replay capsules use a purpose-derived AES key and v2 AAD. A
   read-only legacy v1 fallback remains for the ten-minute replay retention
   window; new writes never use the raw webhook AES key directly.
8. Webhook secret rotation terminalizes pending/retryable deliveries bound to
   the retired version, and request materialization rejects retired or
   non-current versions.

## Consequences

- Existing password hashes upgrade without a forced reset, at the cost of one
  extra derivation and database update on their next successful login.
- Password authentication consumes more CPU. Login rate limits remain the
  capacity guard and must be included in load qualification.
- Misconfigured releases fail during validation or boot instead of degrading
  later into plaintext transport, unavailable encryption, or asymmetric
  worker behavior.
- Webhook rotation becomes an immediate revocation boundary. Queued deliveries
  signed with an old version fail and must be replayed explicitly under the
  current version when appropriate.
- Purpose derivation separates replay and webhook AES-GCM nonce/key domains,
  but possession of the webhook master key still permits derivation. A future
  separate replay master key is an optional stronger compartmentalization
  step.
- This decision does not introduce message E2EE or prove provider-managed
  database, object-storage, backup, or KMS encryption.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Keep the existing controls because deployment validators are documented | Direct image/runtime composition can bypass manual promotion checks; security invariants should fail closed at each relevant boundary. |
| Force every user to reset their password | Operationally disruptive when self-describing PBKDF2 hashes support safe rehash-on-login. |
| Continue queued webhook delivery under retired keys | Rotation would not establish a reliable compromise-revocation boundary. |
| Add message E2EE as part of this change | It changes product, moderation, compliance, search, and multi-device recovery semantics and requires a separate protocol decision. |

## Validation

- Password unit and authentication upgrade tests assert the 600,000-round
  format, legacy verification, missing-identity work, rehash-on-login, and the
  shared failure-response floor for legacy and missing identities.
- Runtime configuration tests reject weak endpoint keys and database URL TLS
  overrides.
- Secret and production-bundle validators include negative tests for active
  key IDs, duplicate/cross-domain material, literal or ConfigMap credentials,
  and edge/worker secret-reference drift.
- Webhook integration tests prove queued old-version deliveries are
  terminalized and retired versions cannot materialize.
- Object-storage and replay-box tests prove the narrowed transport gate,
  purpose-derived replay encryption, and bounded legacy replay compatibility.
