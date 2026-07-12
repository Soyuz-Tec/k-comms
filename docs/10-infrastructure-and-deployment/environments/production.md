# Production Environment

The hardened, provider-neutral application composition is maintained in
`deploy/k8s/overlays/production`. It requires a provider composition for
managed PostgreSQL, durable object storage, secrets/keys, DNS/certificates,
telemetry, alert routing, and restricted network destinations.

Document account/project boundaries, regions and zones, network ranges,
runtime sizing, database class, backup policy, secrets, observability
retention, deployment authority, data policy, and cost budget.

## Readiness checklist

- [ ] Provisioned from approved infrastructure code
- [ ] Access roles reviewed
- [ ] Encryption and backups enabled
- [ ] Monitoring and alert routes tested
- [ ] Synthetic message workflow passes
- [ ] Environment-specific recovery procedure documented

## Application bundle gate

The production overlay must render and pass strict Kubernetes schema validation
in CI. Promotion replaces its candidate image tag with an immutable signed
digest. The retained bundle must contain at least three edge replicas, two
worker replicas, disruption budgets for both roles, autoscaling, restricted
security contexts, TLS ingress, an isolated migration Job, and no in-namespace
PostgreSQL or object-storage StatefulSet.

This validates the application deployment contract only. The checklist stays
open until the selected provider infrastructure and live recovery evidence
exist.
