# Test Strategy

## Test portfolio

| Layer | Purpose | Examples |
|---|---|---|
| Unit | Pure domain rules and validation | Permission, retention, normalization |
| Property-based | Invariants over broad input space | Idempotency, cursor monotonicity, tenant separation |
| Integration | Database, jobs, storage, and PubSub behavior | Transaction rollback, retries, attachment states |
| Contract | API/event compatibility | OpenAPI/AsyncAPI schema checks |
| End-to-end | User-visible journeys | Authenticate, send, receive, reconnect, search |
| Performance | Capacity and latency | Hot rooms, fan-out, reconnect storms |
| Chaos/failure | Recovery and containment | Node kill, database failover, provider outage |
| Security | Abuse and trust boundaries | ID substitution, SSRF, token/session tests |
| Recovery | Backup and DR | Restore, promotion, projection rebuild |

## CI policy

Fast deterministic tests run on every change. Expensive load, soak, chaos, and recovery suites run on scheduled or release-gate pipelines with versioned environments and retained evidence.
