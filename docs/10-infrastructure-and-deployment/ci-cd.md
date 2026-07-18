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
of an already-enforced status, target, mode, retired module namespace, or
retired runtime binding. The one-way promotion from
`strict_with_explicit_deferrals` to `strict` is permitted; every downgrade is
rejected. Changing a finding creates a new fingerprint and therefore fails the
no-growth gate. Comparing to the event's base commit, rather than a mutable
branch name, keeps the result reproducible and prevents a same-branch baseline
or manifest edit from grandfathering new debt or downgrading enforcement.

An architecture-reviewed transition may replace that ordinary no-growth rule
only for one exact preceding baseline hash and exact sorted sets of added and
removed fingerprints. Undeclared additions, undeclared removals, or stale
declared deltas fail. The transition is removed after its resulting baseline
reaches the protected branch.

The paired manifest comparison also reviews semantic permission and ownership
widening, rather than relying only on file hashes. It currently emits exact
review tokens for new contexts; additions to context dependencies, facades,
contracts, internal or owned modules, and published or consumed events; context
kind or graph-scope changes; table ownership, canonical-schema, accessor, role,
external-schema, and access changes; expanded read-model access; new migration
exceptions; new or expanded runtime collaborations and technical interfaces;
and weakened namespace dependency rules. Each detected widening must match an
ADR-backed `enforcement.reviewed_manifest_transitions` entry for the immutable
base manifest's canonical SHA-256, with an exact sorted set of approved change
tokens and a removal condition. This semantic gate covers the listed
permission-bearing declarations; the normal manifest schema, graph, ownership,
and enforcement validators remain responsible for all other manifest
correctness.

Historical truthful-analyzer adoption and explicit-deferral declarations are
preserved in ADRs and reviewed transition history, not as active permission.
Strict mode rejects `baseline_adoption`, `temporary_violations`, and the
`strict_with_explicit_deferrals` policy.

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
configuration binding, and transaction policy. Public facades and contracts
must exist and cannot be Ecto schemas; their specs, callbacks, macrocallbacks,
and type declarations cannot expose persistence schemas. Retired namespaces
are rejected in production and configuration, and retired runtime keys are
rejected both at configuration and `Application` lookup sites.

Strict mode permits no retained fingerprint and requires an empty baseline.
Paired immutable-base comparison prevents the active gate from being disabled
or downgraded and prevents authorization namespace or binding tombstones from
being removed. The ADR-0043 transition removes the exact 29 Calls fingerprints
from canonical baseline SHA-256
`90a52be007eecd64627b35212ec3da314e742f232373a6e954523116f4fa1da6`;
it cannot authorize later growth.
Architecture policy or baseline changes must update the accepted architecture
documentation, validator, and regression tests together and receive
architecture review. The manifest, baseline, generated report, validator,
validator tests, governing ADR, CI workflow, and this CI design document have
explicit `CODEOWNERS` entries.

Repository Actions policy permits GitHub-owned actions plus only the selected
third-party action repositories used by this codebase:
`github/codeql-action`, `erlef/setup-beam`, `azure/setup-kubectl`, and
`docker/login-action`. Repository policy requires every action reference to be
pinned to a full commit SHA. Version comments beside those immutable references
remain review aids, not executable selectors. Workflow files, Dependabot
configuration, and the Trivy policy are architecture-owned through
`CODEOWNERS`.

After warnings-as-errors compilation, the backend job runs two xref gates in
`apps/comms_core`:

- `mix xref graph --format cycles --label compile-connected` must report no
  compile-connected cycles.
- `mix xref graph --format cycles` must report no all-file cycles.

Calls no longer forms a compiled or runtime business-graph cycle. The combined
diagnostic graph may show an SCC formed solely by the opposing directions of
an exact consumer-owned dependency inversion; it does not justify a compiled,
runtime, or file-level cycle. Any new compile or all-file cycle fails CI rather
than becoming a count-based checkpoint.

The `pull-request-smoke` job is emitted for every pull request so it is safe to
make that stable context a required check. It checks the immutable
`pull_request.base.sha` diff for runtime-impacting paths: the Docker and Compose
definitions, root Mix files, application and web-client sources, runtime
configuration, Kubernetes manifests, container-smoke and Compose-exposure
validators, or the container workflow itself. When one changes, the job
validates exposure policy and builds, migrates, boots, and smokes the runtime
image. For documentation-only and other non-runtime changes, the same job
passes as an explicit sentinel instead of disappearing because of workflow path
filtering. Pull-request execution has read-only repository access and never
authenticates to a registry.

The production Kubernetes configuration scan has no rule-wide Trivy ignore.
`.github/trivy/production-ignore.rego` accepts only `KSV-0109` in Trivy
namespace `builtin.kubernetes.KSV0109` for ConfigMap `k-comms-config` in
namespace `k-comms-production`, with the exact currently reviewed message and
flagged-key set. The exception expires at `2026-10-31T00:00:00Z`; any resource,
namespace, message, key-set, or expiry mismatch fails closed. CI also scans the
base ConfigMap as a negative control and requires `KSV-0109` to remain visible,
proving the production-specific exception does not suppress an unrelated
resource.

A push to `main`, or an explicitly requested `workflow_dispatch` run with
`main` selected as its run ref, builds and smokes the exact image tagged
`ghcr.io/soyuz-tec/k-comms:sha-<full-commit-sha>`, then authenticates with the
job-scoped `GITHUB_TOKEN`, pushes it, records the registry digest, and publishes
GitHub build-provenance attestations. A manual run against another branch or tag
skips the publication job. It also uses the digest-pinned Trivy image to create
a CycloneDX JSON SBOM, retains that document with the workflow run, and
publishes a digest-bound SBOM attestation. The workflow pins every publication
action to a reviewed commit and grants write permissions only to the
publication job.

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
