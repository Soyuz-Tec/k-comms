# Staging environment

ADR-0008 is accepted. The executable staging composition is maintained in
`deploy/k8s/overlays/staging`, with the single-host kind qualification overlay
in `deploy/k8s/overlays/local-proof`. Environment authority, prerequisites,
deployment, migration, acceptance, rollback, and evidence boundaries are
documented in:

- `docs/10-infrastructure-and-deployment/environments/staging.md`
- `deploy/k8s/overlays/staging/README.md`
- `docs/07-capacity-and-performance/local-staging-qualification.md`

This directory is intentionally a pointer rather than a second rendered
composition. Keeping one authoritative Kustomize package prevents staging
configuration from drifting between documentation and executable manifests.
