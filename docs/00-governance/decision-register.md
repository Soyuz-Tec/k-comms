# Decision Register

| Decision | ADR | Status | Decision date | Revisit trigger |
|---|---|---|---|---|
| Modular monolith first | ADR-0001 | Accepted | 2026-07-12 | Independent deployment or scaling need |
| PostgreSQL source of truth | ADR-0002 | Accepted for MVP | 2026-07-12 | Proven write or geographic constraint |
| Phoenix real-time stack | ADR-0003 | Accepted for MVP | 2026-07-12 | Connection/fan-out benchmark failure |
| Transactional jobs/outbox | ADR-0004 | Accepted for MVP | 2026-07-12 | Cross-database event platform introduced |
| Object storage for attachments | ADR-0005 | Accepted for MVP | 2026-07-12 | Regulatory or latency requirement |
| Server-readable encrypted messages | ADR-0006 | Accepted for MVP | 2026-07-12 | E2EE product requirement |
| React/TypeScript reference client | ADR-0007 | Accepted for MVP | 2026-07-12 | Client portfolio or accessibility evidence |
| Podman and Kubernetes-neutral platform | ADR-0008 | Accepted for MVP | 2026-07-12 | Provider-specific production decision |
| Voice/video deferred | ADR-0009 | Superseded for audio/video | 2026-07-12 | SIP, recording, transcription, or media-egress approval |
| Corporate OIDC and SCIM identity boundary | ADR-0023 | Proposed | 2026-07-15 | Identity provider selection, SAML requirement, or federated identity implementation |
| Audio-only calls through a LiveKit media plane | ADR-0024 | Superseded for active implementation | 2026-07-15 | Historical audio boundary; see ADR-0025 |
| Unified audio/video calls on the LiveKit media plane | ADR-0025 | Accepted for implementation and internal pilot | 2026-07-15 | Recording, SIP, stricter revocation, group scale, residency, or provider constraint |
| Complete non-audio modularization and activate the strict gate | ADR-0042 | Accepted | 2026-07-17 | Separately authorize and complete the Calls boundary tranche |
