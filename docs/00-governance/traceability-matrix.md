# Requirements Traceability Matrix

Use this matrix to link intended behavior to design, implementation, verification, and operations.

| Requirement | Design artifact | Interface/schema | Verification | Operational evidence | Status |
|---|---|---|---|---|---|
| FR-MSG-001 Send a message | Messaging domain and delivery semantics | REST/WS message command | Integration and idempotency tests | Message-commit SLI | Draft |
| FR-SYNC-001 Recover missed events | Offline synchronization | Sync endpoint/event cursor | Disconnect/reconnect tests | Replay-volume dashboard | Draft |
| NFR-SEC-001 Tenant isolation | Tenant-isolation design | Auth context in every contract | Negative authorization suite | Audit anomaly alerts | Draft |
| NFR-REL-001 Survive one node failure | Deployment and supervision design | N/A | Chaos test | Availability SLI | Draft |

Add one row for each approved functional and non-functional requirement. No critical requirement should enter implementation without an identified verification method.
