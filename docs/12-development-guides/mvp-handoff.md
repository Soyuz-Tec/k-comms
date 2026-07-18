# K-Comms 0.3.0 Engineering Handoff

## Staging-ready product

K-Comms 0.3.0 delivers the MVP as a web-first, multi-tenant communication
platform with separately authorized member, tenant-administration, and
content-blind platform-operations surfaces.

- Password authentication, recovery, rotating sessions, device management,
  step-up authorization, invitations, user lifecycle, and role management
- Direct, group, public-channel, thread, reply, and mention workflows with
  ordered/idempotent messaging, replay, edit/delete, reactions, search, read
  state, typing, presence, and durable in-app notifications
- Version-bound S3-compatible attachment intents, completion verification,
  malware scan workflow, quarantine, safe download, and quota enforcement
- Tenant administration for channels, moderation cases and actions, retention,
  legal holds, deletion requests, audit CSV, notification settings, webhooks,
  and scoped service accounts
- Content-blind platform operations for service health, queues, providers, and
  controlled operational read models
- React/TypeScript responsive interfaces at `/app`, `/admin`, and `/ops`
- Podman local development, Kubernetes-neutral staging/production manifests,
  migrations, metrics, alerts, autoscaling, disruption budgets, and network
  policy
- Idempotent release bootstrap with an immediately deleted credential, plus
  isolated PostgreSQL and MinIO backup/restore and manifest-based rollback
- Automated backend, web, browser, contract, documentation, secret, production
  manifest, container, acceptance, load, rollback, and resilience gates

## Historical local staging qualification

The 2026-07-12 Podman/kind proof ran revision
`bc6ba02536b4bfb703cd5e196d2e431b690a24ad` with two edge replicas and one
worker replica. Baseline acceptance exercised a 25,000,000-byte attachment. The
bounded load gate accepted 300 of 300 messages at 5 messages/second with zero
failures or reconciliation loss, p95 23.13 ms, p99 25.13 ms, and all ten
idempotency probes matching. Edge and worker replacement, rollback
compatibility, roll-forward acceptance, and isolated PostgreSQL and MinIO
backup/restore checks also passed. Those results are superseded for promotion
of any newer candidate, which must produce its own exact-revision evidence.

## Remaining production launch gates

- Select and qualify the production PostgreSQL and object-storage services,
  their backup destinations, access controls, recovery targets, and operators.
- Provision production notification and malware-scanning providers, keys, and
  alert routes; validate outage, rotation, retry, and recovery behavior.
- Provision production DNS and certificates through the selected cluster
  certificate mechanism and external secret/key management.
- Run representative production-scale load, soak, reconnect-storm, zone-loss,
  backup/restore, and disaster-recovery exercises on the selected topology.
- Complete independent security and privacy review, provider/compliance
  approvals, capacity/cost sign-off, support readiness, and staffed on-call
  rehearsal before enabling production traffic.

The local proof is evidence for package correctness and staging readiness, not
a production SLO or substitute for those environment-specific approvals.

## First developer command

```bash
cp .env.example .env
make bootstrap
make dev
```

Open `http://localhost:5173`, choose **Create development workspace**, and use a
password of at least twelve characters.
