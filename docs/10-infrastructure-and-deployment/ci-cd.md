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
direct Repo access outside the non-release test-fixture allowlist. The context
manifest gate also rejects new, changed, or resolved baseline fingerprints,
undeclared or changed SCC edges, unapproved lifecycle-command call sites, and
read-only exceptions that issue owner commands, persistence writes, or raw SQL
DML/DDL. Health and metrics use narrowly named core read APIs rather than
persistence exceptions. Architecture policy or baseline changes must update the
accepted architecture documentation, validator, and regression tests together
and receive architecture review.

Pull requests run the container smoke gate with read-only repository access and
never authenticate to a registry. A push to `main`, or an explicitly requested
`workflow_dispatch` run with `main` selected as its run ref, builds and smokes
the exact image tagged `ghcr.io/soyuz-tec/k-comms:sha-<full-commit-sha>`, then
authenticates with the job-scoped `GITHUB_TOKEN`, pushes it, records the registry
digest, and publishes GitHub build-provenance attestations. A manual run against
another branch or tag skips the publication job. It also uses the digest-pinned
Trivy image to create a CycloneDX JSON SBOM, retains that document with the
workflow run, and publishes a digest-bound SBOM attestation. The workflow pins
every publication action to a reviewed commit and grants write permissions only
to the publication job.

GitHub Actions OIDC obtains a short-lived Sigstore certificate for each signed
attestation. This is the repository's keyless signature boundary; it does not
depend on a separate long-lived cosign private key. Promotion verifies both the
SLSA provenance and CycloneDX predicates against `Soyuz-Tec/k-comms` and the
publication workflow. See
[Supply-chain integrity](supply-chain-integrity.md) for the exact commands and
failure policy.

## Deployment pipeline

- Promote the same immutable artifact between environments.
- Apply safe pre-deploy migrations.
- Deploy a canary or small wave.
- Run synthetic authentication, send, live delivery, replay, and attachment tests.
- Expand traffic while monitoring SLO and resource guardrails.
- Pause or roll back automatically on defined signals.
- Complete post-deploy migrations only after compatibility is verified.
