# Non-functional Requirements

**Status:** Application and local staging baselines are implemented where noted.
Production SLO, capacity, recovery, provider, compliance, and organizational
targets remain unapproved until measured on the selected production
composition. Numeric local measurements below are historical evidence from
revision `bc6ba02536b4bfb703cd5e196d2e431b690a24ad`, not evidence for an
unqualified newer candidate.

| ID | Quality | 0.3.0 requirement or target | Current verification | Status |
|---|---|---|---|---|
| NFR-REL-001 | Availability | The edge and worker roles expose liveness/readiness and support controlled rolling replacement. A 99.95% monthly target remains a proposal. | Two edge replicas and one worker survived exercised pod replacement locally; production error budget and multi-zone evidence do not exist | Partial; production target pending |
| NFR-DUR-001 | Durability | A committed message acknowledgment survives application-node loss and remains replayable from PostgreSQL. | Transactional messaging tests, 300/300 reconciliation, and edge/worker replacement with zero acknowledged-message loss | Implemented for local application-node loss; data-service/zone durability pending |
| NFR-LAT-001 | Latency | The bounded local profile must stay below its explicit 750 ms p95 gate. A production in-region target requires approval. | Historical revision-bound 300-message run at 5 messages/second: p95 23.13 ms and p99 25.13 ms | Historical local gate passed; repeat for every promoted candidate; production target pending |
| NFR-SCL-001 | Scale | Edge and worker roles scale independently without application session affinity. | Distributed node discovery, two edge/one worker proof, HPA/PDB manifests, and reconnect tests | Partial; peak, large-room, reconnect-storm, and multi-zone scaling pending |
| NFR-SEC-001 | Security | Every tenant-owned operation carries explicit tenant and actor context and fails closed at trust boundaries. | Authorization, tenant-isolation, server-side sensitive-operation step-up, session, service-account, provider SSRF, secret-redaction, and manifest tests | Implemented baseline; closure of the separately sealed exact-commit Codex Security result is a promotion gate |
| NFR-PRV-001 | Privacy | Message bodies and one-time credentials stay out of ordinary logs, audit metadata, operations responses, and list projections. | Structured logging, safe presenters, content-blind ops, recovery suppression, and redaction tests | Implemented baseline; production DLP/log sampling and provider privacy approval pending |
| NFR-OPS-001 | Operability | Health, metrics, queues, providers, alerts, dashboards, migration, rollback, and recovery inputs are observable and controlled. | Protected metrics/ops APIs, alert rules, dashboards, runbooks, rollout/rollback, and local restore exercises | Partial; external telemetry, alert routing, support, and staffed on-call pending |
| NFR-MNT-001 | Maintainability | Material behavior is covered by tests, synchronized contracts, ADRs, formatting, warnings-as-errors, and focused modules. | Backend/web/browser/contract/docs/runner/manifest CI gates | Implemented; architecture boundaries are validator-enforced against a reviewed baseline |
| NFR-CMP-001 | Compatibility | Public REST/events evolve additively within v1 and old-image rollback can run against the additive schema window. | Contract synchronization/validation plus old-image rollback and current-image roll-forward proof | Implemented release window; longer client compatibility policy pending |
| NFR-DR-001 | Recovery | Recovery must preserve PostgreSQL records and remap exact object identities only after byte verification. RPO/RTO require business approval. | Historical revision-bound quiesced restore verified 18 attachment rows/10 objects, four ready version-bound remaps, five audit records, restored UI visibility, and an authenticated exact-SHA-256 attachment download; six unversioned legacy rows remained quarantined fail-closed | Historical portable staging gate passed; repeat for every promoted candidate; independent backups, managed PITR/provider recovery, and approved RPO/RTO pending |
| NFR-ABU-001 | Abuse resistance | Bound payloads, identities, tenants, and local request rates without allowing one client to exhaust shared authentication capacity. | Parser/ingress limits, admission quotas, trusted-proxy CIDR/spoof-resistance tests, production auth-ingress limits, node-local IP/account buckets, and bounded load tests | Partial; provider-specific globally distributed edge semantics/load proof remains pending |
| NFR-SUP-001 | Supply-chain security | Lock dependencies, build a non-root release, validate manifests, and reject known high production dependency issues. | Lockfiles, 23 SHA-pinned Action uses, Hex/npm audits, clean Sobelow, Trivy filesystem vulnerability/secret, IaC and image gates, CodeQL JavaScript/TypeScript, digest-pinned build/data/qualification inputs, container smoke, and semantic production preflight | Partial; separately sealed exact-commit Codex Security evidence, signing/provenance, owner license decision, and production registry policy are promotion gates |

Local benchmark values are regression evidence only for their named Git
revision and tested Podman/kind host, not production SLOs or capacity
commitments.
