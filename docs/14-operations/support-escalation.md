# Support Escalation

## Operating rule

Support tools use audited, tenant-scoped access and avoid raw restricted content
unless a documented incident purpose, least-privilege grant, and privacy/security
approval require it. Never ask a user to send a password, session token,
invitation credential, service credential, webhook secret, or unredacted message
history in a ticket.

Before production use, the organization must populate the release-owned roster
for support lead, application engineering, platform/on-call, security/privacy,
incident commander, data-repair approver, and customer/internal communications.
The roster belongs in the approved incident system, not in this public-neutral
repository.

Before the support gate passes, each support role completes a synthetic intake,
severity classification, safe evidence collection, escalation, status update,
handoff, and closure exercise. Retain the reviewer, expiry, exact release and
environment, and restricted evidence URI, then link the aggregate receipt from
`environment.operating_authority`. The pending repository template and a list
of role names are not evidence of staffing or rehearsal.

## Intake contract

Capture:

- reporter contact through the approved support system;
- affected tenant reference and user-safe pseudonymous account reference;
- environment, route/capability, time range with timezone, and release revision;
- user-visible error code and request/correlation ID;
- scope: one user, one tenant, several tenants, or platform-wide;
- whether sending, reading, authentication, attachments, notifications,
  administration, governance, or operations is affected;
- safe reproduction steps and expected/actual behavior; and
- accessibility method, browser/device, and assistive technology when relevant.

Do not paste message bodies or secrets. Attachments and screenshots must follow
the approved restricted-evidence process.

## Severity and response

| Severity | Examples | Immediate route |
|---|---|---|
| Sev-1 | Tenant isolation failure, acknowledged-message loss, widespread authentication outage, active secret exposure | Page incident commander, on-call, and security/privacy; freeze rollout |
| Sev-2 | One-tenant send/read outage, unrecoverable admin lockout, critical accessibility blocker, provider backlog breaching SLO | Page on-call and owning engineer; notify support lead |
| Sev-3 | Recoverable degraded workflow, bounded provider delay, serious but non-blocking accessibility defect | Engineering queue with named owner and target |
| Sev-4 | How-to question, minor visual/copy issue, enhancement | Product/support backlog |

Any suspected privacy, security, cross-tenant, legal-hold, deletion, or audit
integrity issue routes immediately to the security/privacy owner regardless of
apparent blast radius.

## Escalation and authority

- Support may gather content-blind evidence, reproduce in synthetic staging,
  and provide published workarounds.
- Application engineers may diagnose code and data projections but may not
  modify production state outside an approved, audited repair procedure.
- Data repair requires two-person approval, a dry-run, bounded tenant scope,
  backup/rollback plan, immutable script or command receipt, and post-repair
  reconciliation.
- Retention, legal hold, deletion, ownership, or audit changes require the
  appropriate compliance/security authority and must use product APIs where
  available.
- Rollback authority and stop conditions are defined in
  [internal-production-readiness.md](../13-delivery-plan/internal-production-readiness.md).

## Communication and closure

The incident commander owns update frequency, audience, and status wording.
State confirmed impact and mitigations; do not speculate or disclose tenant
content. Closure requires user-impact verification, alert recovery, backlog or
reconciliation checks, evidence retention, ticket links, follow-up owner, and a
problem review for every Sev-1/Sev-2.
