# Authentication and Authorization

## Authentication

- Access tokens are short-lived and audience-bound.
- Refresh tokens are rotated and revocable per device/session.
- Sensitive administration can require step-up authentication.
- Service accounts and bots use separate credentials and scopes.
- Browser WebSockets use a random, hashed, short-lived, one-time socket ticket
  minted through the authenticated REST API. Access and refresh tokens are not
  placed in handshake URLs.

Human sessions combine a sliding inactivity deadline with an immutable
creation-based deadline stored in `sessions.absolute_expires_at`. New sessions
materialize that value from `SESSION_ABSOLUTE_TTL_SECONDS`; existing sessions
were backfilled to 30 days after their insertion time. Refresh rotation uses the
earlier of `now + SESSION_TTL_SECONDS` and the stored deadline. Token/session
lookup, step-up, socket-ticket handling, and database authorization invoked by
established WebSocket commands and intercepted events enforce both deadlines.
Both policy values default to 30 days. Changing the absolute policy affects only
new sessions and cannot extend or shorten a stored deadline.

The account email is the configured password-recovery identity. Ordinary profile
updates may change only the display name; a normalized same-email echo remains
compatible, while any different email fails closed until a separately verified
change-email workflow exists. Invitations enroll only genuinely new human
identities. Existing active or suspended identities conflict, and reactivation
uses the audited, versioned admin lifecycle operation without replacing the
user's password.

Password step-up updates only the current active session and expires after a
short configured window. Legal holds, deletion approvals/cancellation,
security-administrator actions, audit access, and privileged peer-session
controls require an eligible role, recent step-up, and a reason where the
operation changes state.

Tenant-scoped moderation case lists/details and notification intent/attempt
ledgers are role-restricted operational reads and do not themselves require a
fresh password step-up. Their state-changing moderation actions, delivery
retries, integration changes, and governance operations do. Audit reads and
exports remain explicitly step-up protected because they expose a broader
cross-resource evidence surface. These read and mutation policies are enforced
in domain authorization, not only by client route visibility.

Audit CSV export is tenant-filtered before its 5,000-row cap and creates an
`audit.export` evidence record. The export pipeline quotes every cell, strips
NUL bytes, and neutralizes leading spreadsheet formula characters. Free-text
filter contents are not persisted in export evidence, and raw CSV data is never
assembled from the client's already-loaded audit page.

Password recovery is unauthenticated and non-enumerating: known and unknown
tenant/email pairs receive the same `202` body and share a rate-limited,
timing-oriented dummy-work path. Active accounts receive a 15–30 minute,
single-use HMAC-derived token. Only a token hash and request identifiers are
stored; prior outstanding requests are invalidated. The raw token and action
URL are materialized in memory by the notification worker and use the SPA URL
fragment (`/reset-password#token=...`) so HTTP access logs and Referer headers
do not receive the credential. Successful reset revokes every session and
device, disconnects active sockets, emits token-free audit evidence, and does
not create a new login session.

Authentication endpoints enforce both a lower per-IP/account bucket and a
separate IP-wide bucket so rotating tenant/email identifiers cannot bypass the
single-node password-hashing budget. The in-process limiter is a node-local
backstop; production ingress or API-gateway limits remain required for a
distributed deployment.

## Service-account authentication

Service credentials use `kcsa_<uuid>.<secret>` and are shown only once on
creation or rotation. Only a SHA-256 secret digest and non-secret prefix/hint
are stored; verification uses constant-time comparison and a dummy path for
unknown identifiers. They authenticate a dedicated `/api/v1/service/*` pipeline and are
never accepted as human access/refresh tokens, socket tickets, WebSocket
credentials, tenant-admin credentials, or platform roles; human tokens are
likewise rejected on service routes.

An active, unexpired, unrevoked account must hold the route scope and active
conversation membership. The bounded scopes are `conversations:read`,
`messages:read`, `messages:write`, and `search:read`. Scope does not override
tenant, membership, retention, moderation, archived-conversation, message, or
search policy. Admin create/rotate/revoke requires recent step-up, optimistic
version where applicable, and a normalized audit reason. Raw credentials never
enter logs, audit metadata, events, jobs, or list responses.
Expiry defaults to 90 days and is capped at one year. Service identities never
receive email, push, or in-app notification intents; they poll authorized state
through service routes.

## Authorization

Every command evaluates:

- Tenant state
- Actor and session state
- Resource membership or role
- Operation-specific policy
- Content or attachment constraints
- Administrative overrides and audit requirements

A socket join authorizes subscription at that moment; it does not permanently authorize every later command.

Tenant roles (`owner`, `admin`, `compliance_admin`, `security_admin`,
`moderator`, and `member`) do not imply platform authority. A separately
managed `platform_role_grants` row carries a random per-approval identifier,
the role, and exact expiry. Effective values are carried in authenticated HTTP
and one-time socket-ticket subjects
and presented as `platform_role` plus `platform_role_expires_at` on user and
session projections. Platform operations require a current unexpired grant and
an exactly matching internal approval identifier, subject role, and deadline;
expiry, revocation, or renewal therefore takes effect on the next authorization
check, including for an established WebSocket. The internal approval identifier
is not part of the public user/session API. `platform_operator`,
`support_operator`, and `security_operator` may view the content-blind platform
operations snapshot. Mutating platform controls remain restricted to
`platform_operator` unless a narrower permission is explicitly introduced.
Tenant user creation, profile, invitation, and lifecycle APIs cannot assign
platform roles. Audited console grants target only active human users, last from
five minutes through eight hours, and receive a fresh identifier on every grant
or renewal. Revocation clears the grant immediately and may clean up residual
state for an inactive or non-human identity. The rollback-only legacy user
column remains constrained to null so a previous binary cannot bypass the
expiry policy.
