# CI/CD Design

## Continuous integration gates

1. Formatting and static checks.
2. Unit, property, and integration tests.
3. Architecture-boundary and contract-schema checks.
4. Dependency, secret, code, image, and IaC security scans.
5. Reproducible release and container build.
6. Migration safety analysis.
7. Ephemeral-environment smoke tests where practical.

## Deployment pipeline

- Promote the same immutable artifact between environments.
- Apply safe pre-deploy migrations.
- Deploy a canary or small wave.
- Run synthetic authentication, send, live delivery, replay, and attachment tests.
- Expand traffic while monitoring SLO and resource guardrails.
- Pause or roll back automatically on defined signals.
- Complete post-deploy migrations only after compatibility is verified.
