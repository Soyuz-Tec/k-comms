# ADR-0013: Separate service-account authentication from human sessions

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture, identity, security, and messaging
- **Related requirements:** NFR-SEC-001, NFR-AUD-001, NFR-TEN-001, NFR-API-001

## Context

Automations need durable access to tenant conversations without impersonating a
human browser session. Reusing user passwords, access/refresh tokens, socket
tickets, or platform roles would blur principal identity, make credential
rotation unsafe, and grant capabilities unrelated to the automation.

## Decision

K-Comms models each service account as a tenant-scoped principal linked to a
dedicated internal user and device identity for existing membership,
idempotency, message attribution, and audit rules. Service credentials have the
form `kcsa_<uuid>.<secret>`. The random 256-bit secret is returned exactly once
at creation or rotation; only its SHA-256 digest and a non-secret prefix/hint
are persisted and verification uses a constant-time comparison plus dummy work
for unknown identifiers. Rotation immediately invalidates the previous secret.
Expiry and revocation fail closed. Expiry defaults to 90 days and cannot exceed
one year.

Service credentials use a dedicated HTTP authentication pipeline and service
route namespace. They cannot authenticate human, administration, platform,
refresh-token, WebSocket, or socket-ticket routes. Human access tokens cannot
authenticate service routes.

Authorization requires an active tenant, service account, non-login user,
durable service device, conversation membership, and explicit scope:

| Scope | Authority |
|---|---|
| `conversations:read` | List conversations visible to the service principal |
| `messages:read` | Read authorized conversation history |
| `messages:write` | Send idempotent messages to authorized conversations |
| `search:read` | Search only history the service principal may read |

Scopes never bypass tenant, membership, archival, retention, moderation, or
message-validation policy. Tenant owners/admins manage service accounts through
step-up-authenticated admin routes with optimistic versions and a normalized
reason. Create, rotate, revoke, automatic expiry, and message writes produce
principal-specific audit evidence without recording a credential or digest.
Failed authentication is represented only through bounded operational
telemetry so untrusted requests cannot amplify the durable audit ledger.

Service identities never receive email, push, or in-app notification intents;
they consume authorized state by polling the scoped service API.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Reuse a human owner account and refresh token | Little new code | Impersonation, excessive authority, unsafe rotation | Violates principal separation and least privilege |
| OAuth client credentials in the MVP | Familiar standard | Adds issuer, client, and token lifecycle infrastructure | Valuable future option but unnecessary for the bounded MVP |
| API keys accepted on all existing routes | Simple client integration | Easy privilege confusion and accidental admin/socket access | Fails closed-boundary requirement |

## Consequences

### Positive

- Automation actions have a durable, attributable principal.
- Scope, membership, expiry, revocation, and credential rotation compose
  predictably.
- Human and realtime authentication remain unchanged and isolated.

### Negative and accepted trade-offs

- Dedicated service routes duplicate a small part of the human REST surface.
- Tenant administrators must explicitly add the service principal to each
  conversation it should access.
- OAuth federation and delegated consent remain future work.

### Security and operational consequences

The one-time credential must be copied into an approved secret manager and
removed from the browser immediately. Logs, audit metadata, error responses,
jobs, events, and list APIs expose only the credential prefix/hint. Rotation and
revocation require reason, version, recent step-up, and readback verification.

## Validation

- Cross-tenant, missing-membership, missing-scope, expired, revoked, and stale
  credential tests.
- One-time credential presentation and old-secret rejection after rotation.
- Route-matrix tests proving service credentials cannot use human, admin,
  platform, refresh, or WebSocket authentication paths.
- Idempotent send, history, and search tests with tenant-safe audit evidence.

## Revisit triggers

- External customers require OAuth client credentials, federation, delegated
  consent, or third-party marketplace installation.
- Scope count or service-to-service topology outgrows the bounded tenant model.
