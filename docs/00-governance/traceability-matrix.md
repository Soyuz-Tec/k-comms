# Requirements Traceability Matrix

Use this matrix to link intended behavior to design, implementation, verification, and operations.

| Requirement | Design artifact | Interface/schema | Verification | Operational evidence | Status |
|---|---|---|---|---|---|
| FR-ID-001 Authenticate and revoke | Authentication design | Session REST and socket token | Auth/controller and revocation tests | Auth counters | MVP implemented |
| FR-TEN-001 Tenant isolation | Tenant-isolation design | Tenant context in every authenticated contract | Cross-tenant constraints and negative authorization tests | Audit events | MVP implemented |
| FR-CONV-001 Create conversations | Conversation domain | Conversation/member REST | Domain and controller journey tests | Conversation audit/outbox | MVP implemented |
| FR-MSG-001 Send a message | Messaging domain and delivery semantics | REST/WS message command | Concurrent idempotency and ordering tests | Message-commit histogram | MVP implemented |
| FR-SYNC-001 Recover missed events | Offline synchronization | Message page and channel join cursor | Replay/controller and channel tests | Replay logs | MVP implemented |
| FR-FILE-001 Attachments | Object-storage boundary | Attachment intent/complete/download REST | Adapter and controller tests | Object-storage runbook | MVP integrity check; malware gate pending |
| NFR-SEC-001 Secure initial administration | Release bootstrap and ephemeral Secret | Release function; HTTP bootstrap disabled | Idempotency/conflict tests and Kustomize render | Bootstrap Job logs and Secret-deletion evidence | Staging package implemented |
| NFR-REL-002 Recover deployment state | Backup/restore and release strategy | N/A | Isolated PostgreSQL and MinIO restore procedures | Checksums, restore output, approved rendered bundles | Staging procedure implemented; environment rehearsal pending |
| NFR-REL-001 Survive one node failure | Deployment and supervision design | N/A | Staging chaos test | Availability SLI | Production gate pending |

Add one row for each approved functional and non-functional requirement. No critical requirement should enter implementation without an identified verification method.
