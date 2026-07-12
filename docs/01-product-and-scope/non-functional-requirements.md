# Non-functional Requirements

**Status:** Draft seed list

| ID | Quality | Requirement placeholder | Verification |
|---|---|---|---|
| NFR-REL-001 | Availability | Core message acceptance target: proposed 99.95% monthly. | SLI and error budget |
| NFR-DUR-001 | Durability | A committed acknowledgment must survive an application-node failure. | Kill-node test |
| NFR-LAT-001 | Latency | Proposed p95 message acceptance under nominal load: 250 ms in-region. | Load test |
| NFR-SCL-001 | Scale | Horizontal scaling for edge and worker roles without session affinity dependency. | Scale-out test |
| NFR-SEC-001 | Security | Every tenant-owned operation requires explicit tenant and actor context. | Security tests |
| NFR-PRV-001 | Privacy | Message content is excluded from ordinary logs and traces. | Log inspection test |
| NFR-OPS-001 | Operability | Critical failure modes have alerts and tested runbooks. | Game day evidence |
| NFR-MNT-001 | Maintainability | Domain boundaries and dependency rules are checked in CI. | Static architecture test |
| NFR-CMP-001 | Compatibility | Public events and APIs follow additive, versioned evolution. | Contract compatibility tests |
| NFR-DR-001 | Recovery | RPO/RTO values are approved and demonstrated in a recovery exercise. | DR exercise |

All numeric targets are proposals until validated against product value, technical benchmarks, and cost.
