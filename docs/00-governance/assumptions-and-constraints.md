# Assumptions and Constraints

**Status:** Release assumptions resolved; external launch inputs identified

## Baseline assumptions

| ID | Assumption | Validation method | Owner | Target date | State |
|---|---|---|---|---|---|
| A-001 | The first release is a single-region, multi-zone SaaS deployment. | Production overlay, failure model, and external launch approval | Product | 2026-07-12 | Architecture accepted; environment approval external |
| A-002 | PostgreSQL is the authoritative store for accepted messages and memberships. | ADR-0002, constraints, migration and restore tests | Architecture | 2026-07-12 | Accepted and implemented |
| A-003 | Live WebSocket delivery may be missed; clients recover by durable sequence cursor. | AsyncAPI, disconnect/replay, and reconnect-storm tests | Messaging | 2026-07-12 | Accepted and implemented |
| A-004 | Presence and typing indicators are ephemeral and eventually consistent. | Protocol and browser acceptance tests | Product | 2026-07-12 | Accepted and implemented |
| A-005 | Attachments are stored outside PostgreSQL in object storage. | ADR-0005, S3 adapter, scan, backup and restore tests | Platform | 2026-07-12 | Accepted and implemented |
| A-006 | Voice/video is outside the first release. | ADR-0009 and product scope | Product | 2026-07-12 | Accepted |
| A-007 | First-release messages are server-readable with TLS and encryption at rest; true E2EE requires a separate protocol. | ADR-0006 and security architecture | Security | 2026-07-12 | Accepted; E2EE deferred explicitly |
| A-008 | The deployment platform supports rolling updates and horizontal scaling. | Kubernetes rollout, HPA/PDB render, rollback and local failure exercise | Platform | 2026-07-12 | Implemented; managed multi-zone proof external |

## External launch inputs

- Data residency and regulatory jurisdictions.
- Approved workload forecast and representative multi-node fan-out limits.
- Tenant-specific retention, legal-hold, and deletion policy values.
- Target availability, latency, recovery point, and recovery time.
- Supported client platforms and minimum client versions.
- Federation or external protocol compatibility.
- Self-hosted edition requirements.

## Decision rule

An external input may tune a bounded policy or deployment value, but cannot
silently change public contracts, encryption, authorization, data ownership,
or shard boundaries. Such changes require an ADR and the corresponding tests.
