# ADR-0090: Enterprise authentication, provisioning and persistent availability

- **Status:** Accepted
- **Date:** 2026-10-04
- **Owners:** Identity, Security, NotificationDelivery, Calls
- **Related:** ADR-0018, ADR-0023, ADR-0032, ADR-0049, ADR-0075

## Decision

IdentityAccess continues to own all human authentication, sessions, federation
keys, MFA factors, directory lifecycle inputs and user availability. No new
bounded context, deployment unit or cross-context persistence access is added.
The Accounts facade adds explicit authentication, MFA, federation, SCIM and
availability operations. `break_glass_session/1` is an owner-internal console
operation; it is never an HTTP operation. The public facade inventory and its
manifest hash must record the exact operation delta.

OIDC uses Authorization Code, S256 PKCE and independent browser binding, state
and nonce. State is a hashed, five-minute, one-use persisted challenge. The PKCE
verifier is encrypted at rest with identity-specific AEAD keys. A signed,
HttpOnly, SameSite browser cookie binds the callback to its initiating browser.
The configured redirect is exact and allowlisted. Discovery and JWKS endpoints
must use HTTPS on the issuer host; transport validates certificates and
hostnames and refuses redirects. JOSE validates an RSA signature using RS256,
issuer, audience/authorized party, expiry, issuance time, nonce and approved
assurance. Keys shorter than 2048 bits and duplicate key IDs are rejected.
Corporate verification sends `prompt=login` and `max_age=300` and requires a
signed `auth_time` within five minutes. SSO step-up checks the same already
linked subject, tenant, user, and live initiating session before persisting its
proof. SSO-only members can verify through the corporate provider and then
perform sensitive actions without a local password.

The immutable federation key is `(tenant_id, issuer, subject)`. Mutable email
claims cannot link or provision an account. Linking requires the existing,
active, recently verified local session and external subject in one audited
operation. OIDC login requires that explicit link or an approved SCIM subject
mapping for a newly provisioned identity. The mapping defaults off. Federation
has a disabled default and fails closed when secure configuration is absent.

MFA uses NimbleTOTP and independently encrypted factor material. Enrollment
requires recent step-up. Confirmation consumes an authenticator time step and
returns ten independent recovery credentials once; only SHA-256 digests of
high-entropy recovery credentials persist. Sign-in issues no session before
factor verification. Login challenges expire in five minutes and permit five
attempts. Factor failures persist across transactions and lock verification for
five minutes after five failures. A factor time step and each recovery credential
can succeed once. Factor changes and recovery rotation require recent step-up
and a separate factor proof, and revoke other sessions through existing owner
ports. Refresh, authenticated lookup and database-backed authorization require
persisted factor proof once MFA is enabled.
Password changes, password recovery, and factor changes consume pending
password-proof challenges in the same transaction. Password sign-in locks the
current identity and compares its hash with the verified hash before creating
a challenge or session. Legacy hash upgrades use a compare-and-swap and fail
if a concurrent credential change won the race.

SCIM v2 exposes bounded Users and Groups resources with tenant scoped,
revocable `scim:read` and `scim:write` service credentials. Existing service
credential rotation, expiry, revocation and audit controls remain authoritative.
Provisioning is idempotent by exact external ID and creates only ordinary
members. Groups store directory membership and grant no application roles.
Password, role, platform grant and entitlement input is rejected. Mutations use
ETag preconditions, tenant locking and the active-user quota. Suspension and
User deletion revoke sessions, pending authentication challenges, push access
and call admission, and the web adapter disconnects the affected sockets after
commit. User deletion retains a suspended identity tombstone to prevent external
ID reuse; governed privacy erasure separately removes the owned personal data.
The last active human owner cannot be deprovisioned.

A separate, absent-by-default operator recovery credential permits only an
existing active owner's current password and enrolled factor to create a
fifteen-minute session. It never elevates authority or resets MFA. Its immutable
absolute deadline survives refresh. The console command requires operator and
reason attribution and emits `identity.break_glass_used` for mandatory operator
alerting. Custody, alert delivery and drills require operational evidence.

Profiles add an IANA timezone and a bounded PNG avatar. External avatar URLs are
rejected to prevent unsolicited tracking. Ordinary profile updates preserve the
immutable recovery email boundary. Persistent availability consists of manual
state, an optional expiry and a weekly DND schedule in the user's IANA zone,
including overnight and daylight-saving transitions. IdentityAccess returns
only a delivery decision to other contexts. DND keeps in-app messages available,
defer/suppresses email and push before provider work, and suppresses incoming
ringing. It does not prevent a user from voluntarily joining a meeting.

## Persistence and operations

Migration `20261005000400` expands users and sessions and adds
`identity_mfa_factors`, `identity_auth_challenges`, `federated_identities` and
`scim_directory_resources`. Identity encryption keys are independent from
webhook and push keys. Governed erasure clears avatars and availability and
removes federation keys, factors, pending challenges and SCIM personal rows.
Ciphertext keys must remain available until all live material is rotated.

The previous application image can run against the expanded schema while all
enterprise features remain disabled. After MFA or enterprise service scopes
are used, reverting to software that does not enforce them requires a reviewed
identity recovery plan; do not drop the new tables or remove MFA enforcement to
force rollback. A database down migration refuses unsupported retained SCIM
scopes through its restored constraint.

## Validation and qualification

Focused tests cover actual password/MFA/refresh behavior, recovery one-use and
rate bounds, session revocation, explicit OIDC linking, signed issuer fixtures,
protocol negatives, SCIM idempotency and privilege denial, last-owner protection,
credential rotation, tenant isolation, overnight DND and timezone validation.
Rendered settings and callback journeys exercise these commands.

Synthetic signed tokens and local browser APIs are development evidence only.
No actual IdP, SCIM provider or protected production identity has been enabled
or qualified. Corporate promotion additionally requires reviewed issuer/client
registrations, allowed redirects and assurance values, independent secret
custody, an approved sandbox browser journey, deprovisioning/socket latency,
operator recovery alert/drill receipts and protected release qualification.
