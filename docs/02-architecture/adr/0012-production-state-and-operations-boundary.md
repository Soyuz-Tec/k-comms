# ADR-0012: Managed production state and restricted operations boundary

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture, platform, security, and data
- **Related requirements:** NFR-REL-001, NFR-DUR-001, NFR-OPS-001, NFR-DR-001

## Context

The portable staging overlay intentionally runs single-cluster PostgreSQL and
MinIO. It is useful for rehearsal but does not by itself provide multi-zone
durability, independently retained backups, managed key rotation, or a safe
platform-operator boundary.

## Decision

Production uses provider-managed, multi-zone PostgreSQL with point-in-time
recovery and independently verified backups, durable object storage with
versioning and lifecycle policy, a managed secret/key service, automated DNS
and certificate lifecycle, and centralized logs, metrics, traces, and alert
routing. Edge and worker roles remain standard Kubernetes workloads distributed
across failure domains. Provider-specific infrastructure is implemented through
an approved production composition while application manifests remain
Kubernetes neutral.

Operational controls are narrow asynchronous commands backed by domain policy
and audit records. They may expose health, queue, provider, deployment, backup,
restore-verification, incident, and maintenance state. They never expose raw
credentials, arbitrary SQL, shell execution, or unrestricted cluster access.

Numeric SLO, capacity, RPO, and RTO targets are approved before launch and are
demonstrated in production-like exercises.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Promote the portable staging stateful services unchanged | Low initial effort | Weak failure isolation and recovery guarantees | Does not satisfy production durability gates |
| Embed cloud-provider APIs in application domains | Direct control | Provider coupling and broad runtime credentials | Violates application and platform boundaries |
| Expose Kubernetes dashboards as the product ops UI | Existing tooling | Excess authority and poor tenant-aware audit | Not a safe product operations boundary |

## Consequences

### Positive

- Stateful durability and recovery rely on services designed for that purpose.
- Application deployments stay portable across approved Kubernetes platforms.
- Operators receive least-privilege, auditable workflows.

### Negative and accepted trade-offs

- A provider decision and production-specific infrastructure implementation are
  still required for each deployment environment.
- Managed services and independent backup retention increase cost.

### Operational consequences

Production readiness requires restore, node-loss, zone-loss, provider-outage,
rolling-deploy, certificate-rotation, and secret-rotation evidence.

### Security and privacy consequences

Metrics and operations endpoints are private and authenticated. Break-glass
actions require approval, expiry, reason, and immutable audit evidence.

## Validation

- Infrastructure policy, plan, drift, and secret-scanning gates.
- Multi-zone scheduling and disruption-budget checks.
- Isolated restore and regional recovery exercises against stated RPO/RTO.
- Operator authorization and content-exposure tests.

## Revisit triggers

- Evidence supports self-managed stateful services at the required reliability.
- Data residency or scale requires regional decomposition.
