# K-Comms 0.3.0 Software Stack

**Status:** Implemented for 0.3.0. Revision
`bc6ba02536b4bfb703cd5e196d2e431b690a24ad` is the historical locally
staging-qualified baseline; every newer candidate requires exact-revision
qualification. Production providers, managed data services, and
organization-owned delivery systems remain environment-specific launch gates.

The version sources of truth are `.tool-versions`, `mix.lock`, and
`clients/web/package-lock.json`. Container and deployment promotion additionally
requires the retained immutable image digest.

| Layer | Implemented 0.3.0 choice | Current evidence | Status and boundary |
|---|---|---|---|
| Runtime | Erlang/OTP 29.0 and Elixir 1.20.1 | Pinned tool versions, warnings-as-errors build, OTP release and container smoke | Implemented |
| Web/API | Phoenix 1.8.9 on Bandit 1.12.0 | REST, health, metrics, static SPA, and WebSocket tests | Implemented |
| Realtime | Phoenix Channels, PubSub, Presence, and distributed BEAM nodes through libcluster | Replay, authorization, reconnect, session-revocation, and three-node local proof | Implemented locally; production fan-out and zone-loss capacity remain unqualified |
| Authoritative persistence | Ecto SQL 3.14, Postgrex 0.22, and PostgreSQL 17 in the portable staging profile | Migrations, transactional tests, quiesced integrated restore, and node replacement | Implemented; managed production PostgreSQL, PITR, RPO, and RTO remain pending |
| Durable background work | Oban 2.23 with PostgreSQL-backed queues | Notification, webhook, attachment, retention, deletion, retry, and operations tests | Implemented |
| Web client | React 19.2, React Router 7.18, TypeScript 6.0, and Vite 8.1 | Unit, lint, typecheck, production build, and desktop/mobile Playwright journeys | Implemented reference web client |
| Binary storage | Version-bound S3-compatible object storage; MinIO in local and portable staging | Signed upload, checksum/identity verification, scan/quarantine, exact-version download, deletion tests, and guarded restored-version remap proof | Application and portable integrated restore implemented; production object-provider and provider-native recovery qualification remain pending |
| Search | PostgreSQL full-text search constrained by active tenant membership | Authorization and service-account search tests | Implemented; no external search service is part of 0.3.0 |
| Local cache and limits | ETS for bounded node-local state such as rate-limit buckets | Rate-limit, trusted-proxy CIDR/spoof-resistance, production auth-ingress, and runtime tests | Implemented as a local backstop; globally distributed provider-edge semantics and load qualification remain required |
| Identity | Local password authentication, recovery, rotating sessions, device binding, one-time socket tickets, invitations, and scoped service credentials | Authentication, recovery, lifecycle, revocation, and negative-boundary tests | Implemented 0.3.0 identity; OIDC, SAML, SCIM, MFA, and passkeys are future decisions |
| Provider HTTP | DNS-resolved and IP-pinned HTTPS notification, scanner, and webhook adapters with explicit host allowlists | SSRF, response-bound, retry, redaction, and runtime-preflight tests | Implemented adapters; real provider credentials, outage exercises, and compliance approval remain pending |
| Observability | Phoenix/Telemetry instrumentation, Prometheus-compatible metrics, structured logs, dashboards, and alert rules | Metrics authentication, content-blind operations, dashboard, and rule validation | Implemented package; external collection, retention, alert routing, and staffed on-call remain pending |
| Packaging | OCI multi-stage image and Elixir release with digest-pinned build, data-service, and qualification inputs | Non-root container smoke, OCI labels, migration/bootstrap, input-pin review, and immutable promotion procedure | Implemented; substitute the application image digest during promotion; registry signing and provenance policy remain production delivery decisions |
| Orchestration | Kubernetes Kustomize staging/production overlays and Podman/kind local proof | Strict Kubernetes schema validation, rollout, pod replacement, rollback, and roll-forward | Staging package implemented; production cluster/provider composition remains pending |
| Infrastructure | Provider-neutral manifests and runbooks | Render, secret, production-bundle, backup, and promotion validators | Partial; cloud account, DNS, certificate, managed-state, and infrastructure-as-code ownership remain provider decisions |
| CI/CD | GitHub Actions build, test, contract, docs, dependency, release, manifest, SAST, secret, image, IaC, and CodeQL gates; all 23 action uses are commit-SHA pinned | Sobelow passed locally; Trivy filesystem vulnerability/secret, rendered IaC, and image scans passed locally; `.github/workflows/ci.yml` contains equivalent gates | Partial; independently sealed exact-commit Codex Security evidence, signing/provenance, and the owner license decision are evaluated as separate promotion gates |

## Selection guardrail

- Preserve PostgreSQL as the authoritative store for accepted messages and
  memberships.
- Prefer BEAM processes, PostgreSQL, and object storage before adding another
  distributed stateful component.
- Record a new ADR before changing a service boundary, authentication model,
  public protocol, data owner, or deployment topology.
- Treat provider qualification and production organizational approvals as
  explicit gates rather than properties inferred from the local proof.
