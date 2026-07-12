# Engineering Risk Register

**Status:** Draft

| ID | Risk | Probability | Impact | Leading indicator | Mitigation | Owner |
|---|---|---:|---:|---|---|---|
| R-001 | Hot conversations serialize on sequence allocation. | Medium | High | Lock wait and commit latency by conversation | Partitioned sequencing design; benchmark large rooms | Messaging |
| R-002 | Large channels cause excessive real-time fan-out. | High | High | PubSub latency and node mailbox growth | Fan-out budgets, batching, selective delivery, large-room mode | Realtime |
| R-003 | Client reconnect storms overload API and database. | Medium | High | Join rate, sync queries, pool saturation | Jittered reconnect, admission control, cached sync metadata | Realtime/SRE |
| R-004 | Tenant authorization omission leaks data. | Low | Critical | Security tests or anomalous audit access | Mandatory tenant context, query helpers, policy tests, RLS evaluation | Security |
| R-005 | Job retries duplicate notifications or webhooks. | Medium | Medium | Duplicate provider IDs and retry volume | Stable idempotency keys and delivery ledger | Integrations |
| R-006 | Database migration blocks message writes. | Medium | High | Lock duration during staging rehearsal | Expand/contract migration policy and lock-time budgets | Data |
| R-007 | Search projection diverges from source data. | Medium | Medium | Index lag and reconciliation mismatches | Replayable indexing and scheduled reconciliation | Search |
| R-008 | Attachment pipeline becomes malware ingress. | Medium | High | Scan failures, suspicious MIME mismatch | Quarantine-first workflow, scanning, signed URLs | Security/Media |
| R-009 | Observability captures message content or secrets. | Medium | High | Log sampling and DLP findings | Structured allow-list logging and redaction tests | SRE/Security |
| R-010 | Multi-region requirements arrive after incompatible IDs/order assumptions. | Medium | High | Product roadmap change | Region-aware identifiers and home-region ADR before scale-out | Architecture |

## Risk review

Review at each architecture gate and delivery milestone. Critical risks require an explicit acceptance, mitigation plan, or scope change.
