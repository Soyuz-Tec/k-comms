# ADR-0010: Separate product surfaces and administration RBAC

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture, product, and security
- **Related requirements:** FR-ID-001, FR-TEN-001, FR-ADM-001

## Context

The MVP exposes a single reference messaging screen and broad tenant roles. A
production product must let members communicate, tenant administrators manage
their workspace, and platform operators run the service without granting those
actors the same authority or routine access to message content.

## Decision

Keep one React and TypeScript product codebase, with route and authorization
boundaries for `/app`, `/admin`, and `/ops`. User and tenant-administration APIs
remain tenant scoped. Platform-operations APIs use a separate authorization
policy and expose operational metadata rather than message content by default.

Use a fixed permission catalogue with these baseline roles: tenant owner,
tenant administrator, compliance administrator, moderator, member, support
operator, platform operator, and security administrator. Service accounts use
explicit scopes and expiring, revocable credentials. The last active tenant
owner cannot be removed or demoted. Sensitive administration and all
break-glass access require stronger authentication and an auditable reason.

Every privileged command records an append-oriented audit event in the same
transaction as the authoritative change when both share PostgreSQL. Audit
metadata excludes secrets and message bodies.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| One owner/admin role and one UI | Small implementation | Excess authority and poor separation of duties | Does not meet administration or support-access requirements |
| Separate deployed admin frontend | Independent release cadence | Duplicate authentication, components, and delivery pipeline | No demonstrated need for a separate deployment yet |
| Give operators tenant-admin access | Simple support workflow | Routine content access and weak audit boundary | Violates least privilege and privacy goals |

## Consequences

### Positive

- Users, tenant administrators, and operators receive purpose-built workflows.
- Authorization can be tested as an explicit role and permission matrix.
- Shared UI infrastructure avoids duplicating the client platform.

### Negative and accepted trade-offs

- The web client and policy module gain more route and permission complexity.
- Step-up and just-in-time operator access require additional state and tests.

### Operational consequences

Operations endpoints must remain usable during partial provider failures and
must not become a general shell, SQL console, or Kubernetes proxy.

### Security and privacy consequences

Denied privileged attempts, audit reads, exports, approvals, and break-glass
grants are themselves auditable. Support access expires automatically.

## Validation

- Cross-tenant substitution tests for every administrative resource.
- Positive and negative tests for the complete permission matrix.
- Browser journeys for member, moderator, owner, and platform operator.
- Review that operations responses contain no message bodies or credentials.

## Revisit triggers

- A separate admin deployment provides measurable isolation or release value.
- Enterprise customers require custom roles beyond the fixed catalogue.
- Regulatory requirements demand physically isolated support tooling.
