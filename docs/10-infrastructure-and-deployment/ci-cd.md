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
`scripts/validate_architecture.py`. It then runs
`scripts/validate_architecture.py --check-generated-report`; CI fails when the
tracked violation report is not the deterministic rendering of the analyzed
repository and checked-in baseline.

For pull requests, checkout retains full history and CI extracts both
`docs/02-architecture/context-boundary-baseline.yaml` and
`docs/02-architecture/context-boundaries.yaml` from the immutable
`pull_request.base.sha`. The validator receives those files through the paired
`--compare-boundary-baseline` and `--compare-boundary-manifest` options. It
rejects every baseline fingerprint that is new relative to the PR base while
permitting resolved debt to be removed. It also rejects removal or weakening
of an already-enforced status, strict target, strict mode, or active strict
policy. Changing a finding creates a new fingerprint and therefore fails the
no-growth gate. Comparing to the event's base commit, rather than a mutable
branch name, keeps the result reproducible and prevents a same-branch baseline
or manifest edit from grandfathering new debt or downgrading enforcement.

An architecture-reviewed transition may replace that ordinary no-growth rule
only for one exact preceding baseline hash and exact sorted sets of added and
removed fingerprints. Undeclared additions, undeclared removals, or stale
declared deltas fail. The transition is removed after its resulting baseline
reaches the protected branch.

The truthful-analyzer transition also has one content-bound adoption rule for
the pre-endgame 95-finding checkpoint. The manifest records the exact SHA-256
of that baseline and the exact sorted fingerprints exposed only because the
analyzer began attributing previously skipped production modules. Comparison
accepts only those fingerprints and only against that baseline content; all
other growth still fails. The adoption declaration is removed once the
truthful baseline is present on the protected branch.

There is one narrow bootstrap case for the first control-plane merge: if the
immutable PR base does not contain both the boundary baseline and boundary
manifest, the paired comparison emits a visible notice and is skipped only
after the normal validator and deterministic-report checks have passed. The
bootstrap does not accept an invalid manifest, unattributed module, malformed
deferral, or stale report. Once both files exist on the target branch, the
file-presence branch can no longer skip comparison and every later pull request
is subject to both base-SHA fingerprint no-growth and enforcement-state
non-downgrade.

The validator fails on unclassified umbrella apps, forbidden direct dependency
edges, core references to adapter applications, and direct Repo access outside
the non-release test-fixture allowlist. The context manifest gate also rejects
new, changed, or resolved baseline fingerprints, undeclared or changed SCC
edges, unapproved lifecycle-command call sites, and read-only exceptions that
issue owner commands, persistence writes, or raw SQL DML/DDL. Health and
metrics use narrowly named core read APIs rather than persistence exceptions.
It also rejects adapter access to owner-internal core modules and validates
each declared technical interface's exact caller, every declared operation,
any undeclared operation, non-empty public contracts, behavior, implementation,
configuration binding, and transaction policy.
Strict mode requires every retained fingerprint to map exactly once and to
belong to the exact Calls tranche. Removing the allowed Calls nodes from a
mixed SCC must not leave a cycle. Paired immutable-base comparison rejects all
strict-mode additions before any reviewed transition can adopt them and
prevents the active strict gate from being disabled or downgraded. A generic
non-audio deferral therefore fails even when its fingerprint is listed.
Architecture policy or baseline changes must update the accepted architecture
documentation, validator, and regression tests together and receive
architecture review. The manifest, baseline, generated report, validator,
validator tests, governing ADR, CI workflow, and this CI design document have
explicit `CODEOWNERS` entries.

After warnings-as-errors compilation, the backend job runs two xref gates in
`apps/comms_core`:

- `mix xref graph --format cycles --label compile-connected` must report no
  compile-connected cycles.
- `mix xref graph --format cycles` must report no all-file cycles.

Calls remains an explicit business-graph SCC in the generated architecture
report, but it does not justify file-level xref cycles. Any new compile or
all-file cycle fails CI rather than becoming a count-based checkpoint.

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
