# ADR-0049: Add conversation guest links and convertible guest identities

- **Status:** Accepted
- **Date:** 2026-07-24
- **Owners:** Architecture, IdentityAccess, Conversations, ConversationContent,
  Calls, Security, and Web
- **Related decisions:** ADR-0001, ADR-0017, ADR-0018, ADR-0025, ADR-0027,
  ADR-0033, ADR-0034, ADR-0038, ADR-0040, ADR-0043, ADR-0045, ADR-0046

## Context

Members need a low-friction way to start a bounded conversation with someone
outside their workspace. A recipient must be able to scan a QR code or open a
shared link, enter one display name, and communicate without first creating a
permanent account. Account creation remains optional and must preserve the
guest's conversation identity and history.

The existing tenant invitation is not this capability. It is an email-bound
workspace-enrollment workflow that creates a permanent human identity. Reusing
it would couple a conversation share to tenant administration, require account
creation before communication, and grant a wider application surface than the
recipient needs. A browser-only token or synthetic membership would also fail
to provide authoritative expiry, revocation, quota enforcement, audit
attribution, and call authorization.

This change extends the same protected branch as ADR-0046. The reviewed
manifest transition in `context-boundaries.yaml` therefore adopts the exact
three ADR-0046 projection additions and the exact guest-access additions in one
cumulative ADR-0049 transition against the unchanged protected-base digest.

## Decision

Keep guest communication inside the existing modular monolith and preserve one
release, one PostgreSQL database, and the existing business-context directions.

### Ownership and transaction boundary

1. Conversations owns conversation guest links, redemptions, admission history,
   membership admission, history start sequence, use counts, expiry, durable
   expiry scheduling, and revocation. It owns `conversation_guest_links` and
   `conversation_guest_admissions` and exposes only Ecto-free
   `GuestLinkView` and `GuestAdmissionView` projections.
2. IdentityAccess owns temporary guest users, devices, sessions, guest access
   validation, refresh rotation, and guest-to-human conversion. It reuses its
   existing `users`, `devices`, and `sessions` tables and exposes the bounded
   guest fields through its existing Ecto-free `AccessGrant`, `AccessContext`,
   `AuthenticationResult`, and owner projections. It does not add a duplicate
   guest-only authorization DTO.
3. Conversation redemption runs in one Conversations-owned database
   transaction. Conversations locks and validates the link, enforces
   conversation capacity, asks the existing IdentityAccess facade to provision
   the bounded guest identity on that transaction, creates membership and
   admission rows, advances the use count, and commits or rolls back the whole
   admission.
4. Conversations may call IdentityAccess because that dependency already
   points in the approved direction. IdentityAccess does not import
   Conversations. No new service, database, shared kernel, runtime port, or
   dependency cycle is introduced.
5. Guest admission counts toward existing active-user and
   conversation-member quotas. A link never bypasses tenant state,
   conversation state, call policy, or active-membership authorization.

### Link and QR security

1. Only an active conversation owner or moderator may list, create, or revoke
   links. Direct conversations cannot create guest links.
2. Creation accepts a 900-to-86,400 second lifetime and one-to-25 uses. Defaults
   are 86,400 seconds and 10 uses. The raw high-entropy token and complete
   `/join#guest=...` share URL are returned once; PostgreSQL stores only the
   token's SHA-256 digest.
3. Links are communication-only by default. Account conversion can be enabled
   only by a tenant owner or administrator with a recent step-up, requires one
   preauthorized normalized email, and forces the link to a single use. Creation
   also generates an independent 256-bit conversion-verification secret. Its
   domain-bound 32-byte digest is stored on the exact guest-link row, while the
   plaintext verification code is returned only once to the authenticated
   creator and is deliberately excluded from the share URL and QR. Public link
   projections expose only whether conversion is enabled and a masked email
   hint; they never expose the stored email, verification code, or digest.
4. The browser generates the QR locally from the returned share URL and clears
   the fragment immediately after reading it. The token is sent only in POST
   bodies. It is never written to an HTTP path, query string, log, audit
   metadata, event, WebSocket payload, or QR table.
5. Preview returns the dedicated `GuestLinkPreviewView` and discloses exactly
   the room display title, link expiry, conversion eligibility, and masked
   email hint. It does not expose tenant or conversation identifiers, kind,
   visibility, sequence or activity metadata, capabilities, versions, or
   internal timestamps. Unknown, malformed, expired, exhausted, and revoked
   tokens return the same public `guest_link_unavailable` result.
6. Redemption starts message visibility at the conversation's current next
   sequence. A guest link never exposes pre-admission history.
7. Revocation prevents further redemption, disconnects derived guest sockets,
   and revokes sessions and active admissions derived from that link. Every
   redemption also schedules an idempotent durable expiry job that removes the
   membership, session, active-user quota use, and call access at the admission
   deadline. The normal membership-removal path remains available for one guest
   without invalidating unrelated admissions.

### Scoped guest session and optional conversion

1. Guest sessions use a separate bearer-token purpose and a separate
   `/api/v1/guest/*` pipeline. Normal human and service authentication reject
   guest tokens, and guest tokens are rejected by ordinary member, admin,
   operations, and service routes.
2. A guest session's immutable absolute deadline is no later than its admission
   and link expiry. Refresh rotation cannot extend that deadline.
3. Guest routes expose only the admitted conversation, active sanitized member
   projections, post-admission messages, read cursor, one-time socket ticket,
   and membership-authorized audio/video call lifecycle. Directory, search,
   files, other conversations, notifications, tenant administration,
   governance, integrations, and operations remain unavailable.
4. Optional conversion is available only when the creating tenant owner or
   administrator preauthorized the exact email on a recently stepped-up,
   single-use link. Conversion changes the same guest `users.id` to a human
   identity only after that normalized email matches, the separately delivered
   `verification_code` matches the row's digest in constant time inside the
   locked conversion transaction, and the password satisfies normal
   IdentityAccess rules. The locked tenant, conversation, link, admission,
   membership, and email relationships bind the challenge to the admitted
   identity. It revokes the guest session/device and creates a fresh normal
   human device/session. Conversation membership, message authorship, call
   history, and audit attribution remain attached to the same user identifier.
5. All link creation, redemption, revocation, guest-session revocation, and
   conversion mutations emit token- and verification-code-free tenant-scoped
   audit evidence.
6. Account-conversion attempts use a separate five-per-minute per-IP and
   per-identity limiter so password hashing cannot become a guest-authenticated
   CPU denial-of-service path.
7. The verification-digest migration disables conversion on any pre-existing
   account-enabled link because no safe plaintext verifier exists to backfill.
   The creator must issue a new stepped-up, single-use link and deliver its new
   verification code separately.

### Rollback compatibility

1. A redeemed link persists `users.account_type = 'guest'` and schedules
   `CommsWorkers.GuestAdmissionExpiryWorker`. Expiry revokes authority and moves
   the deadline but deliberately retains the guest identity row and its
   `account_type`; only successful account conversion changes it to `human`.
2. Code predating this ADR cannot decode the new Ecto enum value or execute the
   scheduled worker. Therefore any persisted guest row, including an expired or
   revoked guest, or any active guest-expiry job prevents application rollback
   to a pre-guest release.
3. Guest-aware receipts declare `guest_identity_v1` and
   `guest_admission_expiry_worker_v1`. The local release manager quiesces writes
   and probes both hazards before restoring a receipt without those
   declarations. It fails closed without deleting or rewriting guest data.
4. A release train that requires working rollback after guest use must first
   retain a guest-compatible bridge release, or use roll-forward recovery.

### Migration operations and abort criteria

IdentityAccess-owned migration `20260724000165` establishes the unique
`sessions (tenant_id, user_id, id)` key before the Conversations-owned guest
schema references it. Migration `20260724000190` is the forward Conversations
schema reconciliation for databases that applied an earlier shape of
`20260724000170` or `20260724000180`; environments that already recorded those
versions still apply the newly introduced `20260724000165` prerequisite first.
The 2026-07-24 `k_comms_dev` rehearsal measured 17 guest links, 13 admissions,
54 memberships, and 40 sessions. It found zero missing membership/session
targets, zero membership tenant/conversation/user mismatches, and zero session
tenant/user mismatches. Two conversion-enabled links lacked a verification
digest; the migration deliberately clears only those unverifiable emails.
Every environment must re-run this preflight instead of treating those local
counts as a production estimate:

```sql
SELECT count(*) FROM conversation_guest_links;
SELECT count(*) FROM conversation_guest_admissions;
SELECT count(*) FROM conversation_memberships;
SELECT count(*) FROM sessions;

SELECT count(*) AS membership_owner_or_missing_mismatches
FROM conversation_guest_admissions AS admission
LEFT JOIN conversation_memberships AS membership
  ON membership.id = admission.membership_id
WHERE membership.id IS NULL
   OR (membership.tenant_id, membership.conversation_id, membership.user_id)
  IS DISTINCT FROM
  (admission.tenant_id, admission.conversation_id, admission.guest_user_id);

SELECT count(*) AS session_owner_or_missing_mismatches
FROM conversation_guest_admissions AS admission
LEFT JOIN sessions AS session ON session.id = admission.session_id
WHERE session.id IS NULL
   OR (session.tenant_id, session.user_id)
  IS DISTINCT FROM (admission.tenant_id, admission.guest_user_id);

SELECT membership_id, count(*)
FROM conversation_guest_admissions
GROUP BY membership_id
HAVING count(*) > 1;

SELECT count(*) AS unverifiable_conversion_links
FROM conversation_guest_links
WHERE conversion_email IS NOT NULL
  AND conversion_verification_digest IS NULL;
```

The migration runs in one PostgreSQL DDL transaction. It briefly takes schema
locks while it replaces the guest admission foreign keys and checks, builds
three Conversations-owned non-concurrent unique indexes, validates the new
relationships, and updates only unverifiable conversion links. The preceding
`20260724000165` migration builds the one IdentityAccess-owned sessions index.
Index work scales with guest links, admissions, memberships, and sessions;
constraint validation scans the referencing and referenced rows. Before
promotion, record those row counts, rehearse duration on a production-shaped
copy, set bounded lock and statement timeouts in the migration runner, and
quiesce guest link creation, redemption, conversion, and admission expiry
writes for the measured window.

Release migrations enforce those conditions rather than relying on operator
memory. `CommsCore.Release.migrate/0` runs only in an identified one-shot
runtime with explicit quiescence confirmation, verifies the configured
PostgreSQL `lock_timeout` and `statement_timeout`, and refuses to start while
any differently identified database client remains connected. Local release,
staging, and production procedures stop edge/application and worker writers
before invoking it. Kubernetes migration Jobs use `backoffLimit: 0`, so a
failure must be investigated and deliberately recreated instead of being
retried automatically.

There is no safe mid-migration pause or partial resume: a lock timeout,
constraint violation, or index failure rolls back the transaction. Leave the
schema version unapplied, investigate the offending rows or lock holder, and
rerun the same migration after correction. Do not manually mark it complete.
Monitor `pg_stat_activity`, `pg_locks`, `pg_stat_progress_create_index`,
PostgreSQL errors, replication lag, and `schema_migrations`; after completion,
verify every named index is valid and every replacement constraint is
validated.

Abort before promotion if any membership/session owner or missing-target count
is nonzero, an admission membership is duplicated, estimated lock time exceeds
the maintenance window, replication lag breaches the deployment threshold, or
the production-shaped rehearsal cannot create and validate every object.
Unverifiable conversion-link rows are the one expected data repair and must be
counted in the change record. The migration's `down` direction intentionally
re-runs the reconciliation instead of weakening ownership during a partial
rollback.

Kubernetes rollback uses the current guest-aware image to run
`CommsCore.Release.assert_guest_rollback_compatible!/0` after edge and worker
quiescence. The exact target bundle must declare identical guest rollback
capabilities on both pod templates. A legacy, partial, missing, or mismatched
declaration is accepted only when PostgreSQL has zero persisted guest users and
zero active guest-expiry Jobs; otherwise an approved guest-compatible bridge or
roll-forward is mandatory.

Direct schema rollback is forbidden. Ecto's `:down, to:` strategy includes the
requested migration version: `20260724000190` re-runs reconciliation, while
`20260724000180` drops verification digests, `20260724000170` drops guest link
and admission tables, and `20260724000160` rewrites guest identities before
removing their fields. `CommsCore.Release.rollback/2` therefore refuses every
request before loading the application or opening PostgreSQL. Application
rollback restores only a qualified image after the compatibility preflight;
schema recovery restores a verified backup or applies an explicitly reviewed
forward repair.

ADR-0046 remains authoritative for its bounded mobile member read projections.
This ADR adopts those three manifest additions only so the branch has one exact
reviewed transition for the protected-base digest; it does not alter ADR-0046's
contracts or rationale.

## Consequences

- A recipient reaches communication with one link/scan and one display-name
  submit, while account creation stays optional.
- Guest authority is durable, expiring, revocable, quota-bound, and auditable
  instead of being inferred by Web.
- Communication remains one link plus one display-name submit. Permanent
  enrollment is deliberately a separate, administrator-preauthorized choice.
- A converted guest keeps one stable identity and conversation history without
  copying records or rewriting foreign keys.
- QR generation adds no server-side image storage or token-bearing event.
- Separate guest authentication and allow-listed routes add implementation and
  test surface, but keep permanent-member authorization closed by default.
- Link revocation may terminate active guest communication, which is the
  deliberate safety behavior surfaced to the host before confirmation.
- Once any guest identity is persisted, a pre-ADR-0049 binary is no longer a
  valid rollback target. The boundary clears only if every guest row is
  converted by the supported product workflow and every associated expiry job
  is terminal; expired or revoked identities remain `guest`, so normal guest
  use makes the boundary permanent for that database.

## Alternatives rejected

| Alternative | Reason rejected |
|---|---|
| Require account creation before joining | Adds friction and does not satisfy optional enrollment. |
| Reuse email invitations | Invitations grant tenant enrollment and are not conversation-scoped or QR-first. |
| Encode authority entirely in a signed URL | Cannot enforce use counts, immediate revocation, admission history, or transactional quotas safely. |
| Store or render QR images at the server | Creates unnecessary token-bearing artifacts and lifecycle obligations. |
| Give guests normal member tokens | Makes route isolation depend on scattered authorization checks and risks admin or directory exposure. |
| Copy a guest into a new human user on conversion | Breaks authorship and membership continuity and creates reconciliation work. |
| Create a Guest service or bounded context | Guest access is a collaboration between existing Conversations and IdentityAccess capabilities, not an independently deployable capability. |

## Validation

- Domain and concurrency tests cover creation bounds, one-time raw-token
  return, digest-only persistence, uniform unavailable results, atomic use
  limits, capacity races, cross-tenant denial, scheduled idempotent expiry,
  roster/quota/call cleanup, history cutoff, revocation, and rollback.
- Identity tests prove guest absolute expiry, separate token purposes, refresh
  bounds, normal-route denial, same-user conversion, old-session revocation,
  preauthorized email matching, conversion privilege and step-up, single-use
  enforcement, and unique-email/password enforcement.
- Controller and OpenAPI tests cover every host, public-exchange, guest-scoped,
  call, socket-ticket, refresh, logout, and conversion route and confirm that
  no response leaks a token digest or owner-internal schema.
- Web tests cover fragment removal, local QR generation, copy/share fallback,
  one-submit admission, inaccessible pre-admission history, revocation messaging,
  optional conversion, keyboard use, and narrow-screen layouts.
- Release tests cover guest-only and expiry-job-only rollback hazards, a
  guest-compatible predecessor, application quiescence before the final probe,
  compatible current-release restoration on a blocked manual rollback, and
  fail-closed automatic rollback, `Start`, and `Rollback` behavior when a
  migrated failed candidate leaves the recorded pointer on legacy code.
- The executable boundary manifest declares the two new Conversations public
  contracts and two Conversations-owned tables. Architecture regression tests preserve the
  Accounts-to-Conversations prohibition, owner-only persistence, Ecto-free
  public DTOs, empty violation baseline, and exact cumulative ADR-0049
  transition.
- Contract validation requires the guest routes, separate guest bearer scheme,
  bounded create/convert bodies, uniform public error contract, and byte-for-byte
  OpenAPI mirror parity.
