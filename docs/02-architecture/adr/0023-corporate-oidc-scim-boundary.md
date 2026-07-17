# ADR-0023: Define the corporate OIDC and SCIM identity boundary

- **Status:** Proposed
- **Date:** 2026-07-15
- **Owners:** Identity, Platform, Security
- **Reviewers:** Product, Privacy, Operations
- **Related requirements:** FR-ID-001, internal-production identity gate

## Context

K-Comms 0.3.0 implements tenant-local passwords, recovery, invitations, and
rotating sessions. Corporate deployment may instead require an enterprise
identity provider to authenticate people, enforce MFA, and provision or suspend
accounts through SCIM. Those capabilities are not implemented in 0.3.0, and a
configuration declaration must never be mistaken for working federation.

The identity provider can establish who a person is, but it must not become an
authorization source for tenant roles, conversation membership, moderation,
governance, service credentials, or platform-operation grants. Email is mutable
and therefore cannot safely be the durable federation key.

## Decision

Introduce a provider-neutral deployment contract with these reviewed,
non-secret values:

| Setting | Development value | Corporate target value | Meaning |
|---|---|---|---|
| `ALLOW_DEVELOPMENT_IDENTITY_MODES` | `true` | `false` | Explicitly permits local-only identity modes |
| `IDENTITY_PROVIDER_MODE` | `local_password` | `oidc` | Selects the declared human-authentication policy |
| `DIRECTORY_PROVISIONING_MODE` | `manual` | `scim` | Selects the declared account-lifecycle policy |
| `OIDC_ISSUER` | empty | Exact HTTPS issuer identifier | Stable issuer half of the federated subject key |
| `OIDC_CLIENT_ID` | empty | Registered non-secret client identifier | Audience expected by K-Comms |
| `OIDC_PROVIDER_NAME` | empty | Reviewed provider label | Operator-visible, non-secret provider identity |
| `OIDC_REQUIRED_ACR_VALUES` | empty | Provider-approved assurance values | Minimum corporate authentication assurance policy |
| `SCIM_PROVIDER_NAME` | empty | Reviewed provider label | Operator-visible, non-secret provisioning authority |

Production semantic preflight requires the corporate target values, rejects
the development gate and modes, validates the OIDC issuer as an HTTPS URL on
port 443, and rejects missing or placeholder provider metadata. Portable
staging remains explicitly on `local_password` plus `manual` with the
development gate enabled.

The future implementation must additionally enforce all of the following:

- Use the exact validated pair `(iss, sub)` as the immutable external identity
  key. Email and display name are attributes, never account-linking keys.
- Use Authorization Code with PKCE and validate issuer, audience, signature,
  expiry, state, nonce, redirect URI, and the approved assurance claim. Never
  accept an ID token or access token from a different issuer or client.
- Make account linking an explicit, audited operation that proves the existing
  K-Comms session and the external subject. Automatic email-based linking is
  forbidden.
- Treat SCIM as lifecycle input only. Provisioning, suspension, and group
  mapping remain tenant-scoped and idempotent; SCIM groups cannot assign owner,
  security, compliance, moderator, or platform roles without a separately
  approved mapping and K-Comms authorization checks.
- Revoke K-Comms sessions and socket access promptly when a linked identity is
  suspended. Provider logout alone is not local revocation evidence.
- Keep one audited, time-bounded break-glass owner path outside the normal IdP
  dependency, with separately held credentials, alerting, and regular drills.

This ADR defines a boundary and promotion contract only. It does **not** claim
that OIDC login, IdP-enforced MFA, SCIM endpoints, account linking, group
mapping, or deprovisioning are implemented or qualified. A production release
still requires those code paths, security review, sandbox/provider tests, and
an exact-candidate end-to-end receipt.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Keep local passwords for corporate production | No federation implementation | No IdP-enforced MFA or centralized lifecycle | Remains possible only through an explicitly approved compensating-control decision, not this target contract |
| Link identities automatically by email | Simple migration | Mutable, recycled, and sometimes unverified attribute | Account-takeover risk |
| Trust IdP groups as application roles | Central administration | External configuration could grant sensitive tenant or platform authority | Violates the K-Comms authorization boundary |
| Implement SAML and OIDC together | Broad provider coverage | Doubles protocol and validation surface | OIDC is the first bounded corporate target; SAML requires a later decision |

## Consequences

### Positive

- Production composition cannot silently retain local development identity
  policy while claiming corporate OIDC and SCIM readiness.
- External identity remains separate from K-Comms tenant authorization.
- Stable subject linking, deprovisioning, MFA assurance, and break-glass
  expectations are explicit before implementation begins.

### Negative and accepted trade-offs

- The provider-neutral production overlay continues to fail preflight until a
  provider composition supplies the reviewed contract.
- This slice does not provide a usable SSO or SCIM flow and therefore does not
  close the internal-production identity gate.

### Operational consequences

- Identity owners must supply exact issuer/client registrations, redirect
  origins, assurance values, SCIM lifecycle semantics, group mappings, and
  break-glass custody before qualification.
- Provider secrets remain outside this non-secret contract and must be added to
  the external secret inventory only when an implementation consumes them.

### Security and privacy consequences

- Federation identifiers and lifecycle events become personal data subject to
  tenant isolation, minimization, retention, audit, and deletion policy.
- Authentication assurance never grants application authorization by itself.

## Validation

- Focused production-bundle tests reject local-password/manual modes, an enabled
  development gate, placeholder provider metadata, and an invalid issuer.
- Future implementation tests must cover OIDC positive and negative protocol
  cases, explicit linking, duplicate subjects, SCIM idempotency and suspension,
  role-escalation denial, session/socket revocation, provider outage, and
  break-glass use.
- Promotion requires an exact-candidate browser/API journey against the approved
  corporate sandbox plus a deprovisioning latency receipt.

## Revisit triggers

- SAML, multiple simultaneous issuers, customer-managed identity, just-in-time
  provisioning, passkeys, or cross-organization federation become requirements.
- The selected provider cannot supply stable subjects or an approved assurance
  signal.
