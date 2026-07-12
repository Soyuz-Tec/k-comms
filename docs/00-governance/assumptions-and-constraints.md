# Assumptions and Constraints

**Status:** Draft

## Baseline assumptions

| ID | Assumption | Validation method | Owner | Target date | State |
|---|---|---|---|---|---|
| A-001 | The first release is a single-region, multi-zone SaaS deployment. | Product and risk approval | Product | TBD | Open |
| A-002 | PostgreSQL is the authoritative store for accepted messages and memberships. | Architecture spike and ADR | Architecture | TBD | Proposed |
| A-003 | Live WebSocket delivery may be missed; clients recover by durable sequence cursor. | Protocol review and failure test | Messaging | TBD | Proposed |
| A-004 | Presence and typing indicators are ephemeral and eventually consistent. | Product acceptance | Product | TBD | Proposed |
| A-005 | Attachments are stored outside PostgreSQL in object storage. | Security and cost review | Platform | TBD | Proposed |
| A-006 | Voice/video is out of the first release unless separately funded. | Scope approval | Product | TBD | Open |
| A-007 | End-to-end encryption is a pre-implementation architectural decision. | Security/product decision | Security | TBD | Open |
| A-008 | The deployment platform supports rolling updates and horizontal scaling. | Infrastructure proof of concept | Platform | TBD | Proposed |

## Constraints to resolve

- Data residency and regulatory jurisdictions.
- Maximum channel membership and fan-out behavior.
- Retention, legal hold, and deletion requirements.
- Target availability, latency, recovery point, and recovery time.
- Supported client platforms and minimum client versions.
- Federation or external protocol compatibility.
- Self-hosted edition requirements.

## Decision rule

An assumption that affects public contracts, encryption, data retention, or shard boundaries must be resolved before implementation of the affected subsystem begins.
