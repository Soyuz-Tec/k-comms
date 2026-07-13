# CI/CD Design

## Continuous integration gates

1. Formatting and static checks.
2. Unit, property, and integration tests.
3. Architecture-boundary and contract-schema checks.
4. Dependency, secret, code, image, and IaC security scans.
5. Reproducible release and container build.
6. Migration safety analysis.
7. Ephemeral-environment smoke tests where practical.

The architecture gate runs `scripts/test_validate_architecture.py` followed by
`scripts/validate_architecture.py`. It fails on unclassified umbrella apps,
forbidden direct dependency edges, core references to adapter applications, and
direct Repo access outside the non-release test-fixture allowlist. Health and
metrics use narrowly named core read APIs rather than persistence exceptions.
Architecture policy changes must update the accepted architecture documentation,
validator, and regression tests together.

Pull requests run the container smoke gate with read-only repository access and
never authenticate to a registry. A push to `main`, or an explicitly requested
`workflow_dispatch` run, builds and smokes the exact image tagged
`ghcr.io/soyuz-tec/k-comms:sha-<full-commit-sha>`, then authenticates with the
job-scoped `GITHUB_TOKEN`, pushes it, records the registry digest, and publishes
GitHub build-provenance attestations. The workflow pins every publication action
to a reviewed commit and grants write permissions only to the publication job.

## Deployment pipeline

- Promote the same immutable artifact between environments.
- Apply safe pre-deploy migrations.
- Deploy a canary or small wave.
- Run synthetic authentication, send, live delivery, replay, and attachment tests.
- Expand traffic while monitoring SLO and resource guardrails.
- Pause or roll back automatically on defined signals.
- Complete post-deploy migrations only after compatibility is verified.
