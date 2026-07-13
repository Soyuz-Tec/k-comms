# Local Staging Load and Soak Qualification

## Purpose and evidence boundary

`scripts/staging_load.mjs` provides safe, repeatable message-acceptance
qualification for the local Podman staging candidate or an authorized staging
origin. It uses only Node.js 22 built-ins plus the repository's staging
acceptance helpers. No package installation is required.

The runner creates a new private group conversation for every run. It sends
only to that conversation, retries selected messages with the identical
`Idempotency-Key`, reads canonical history in bounded pages, and verifies
ascending sequence order and acknowledged-message presence. In all exit paths
it attempts to archive the run conversation and revoke the run-scoped device;
logout is the fallback. It never deletes a conversation or selects a preexisting
conversation for load.

The result is local package and regression evidence. It does **not** prove a
production SLO, safe per-node capacity, multi-node fan-out, failure headroom,
or production cost.

## Credential setup

Use a temporary synthetic owner or administrator created for acceptance. Supply
the required values through the current shell or an approved secret-injection
mechanism; do not place them in Git, command arguments, evidence files, or shared
shell transcripts.

Required variables:

- `K_COMMS_BASE_URL`
- `K_COMMS_TENANT_SLUG`
- `K_COMMS_OWNER_EMAIL`
- `K_COMMS_OWNER_PASSWORD`

For a private certificate authority, set `NODE_EXTRA_CA_CERTS` to the approved
CA file. Never disable TLS verification. `node scripts/staging_load.mjs --help`
lists every bound and default.

## Proposed local qualification profile

The default invocation is a small observation run: 30 messages, concurrency 3,
10-second send window, and three duplicate probes. Qualification must set its
thresholds explicitly:

```powershell
$env:K_COMMS_LOAD_MESSAGES = "300"
$env:K_COMMS_LOAD_CONCURRENCY = "6"
$env:K_COMMS_LOAD_DURATION_SECONDS = "60"
$env:K_COMMS_LOAD_DUPLICATE_PROBES = "10"
$env:K_COMMS_TIMEOUT_MS = "15000"
$env:K_COMMS_LOAD_MAX_RUN_SECONDS = "1800"
$env:K_COMMS_LOAD_MAX_P95_MS = "750"
$env:K_COMMS_LOAD_REQUIRE_ZERO_LOSS = "true"
node scripts/staging_load.mjs
```

The same profile in a POSIX shell:

```bash
K_COMMS_LOAD_MESSAGES=300 \
K_COMMS_LOAD_CONCURRENCY=6 \
K_COMMS_LOAD_DURATION_SECONDS=60 \
K_COMMS_LOAD_DUPLICATE_PROBES=10 \
K_COMMS_TIMEOUT_MS=15000 \
K_COMMS_LOAD_MAX_RUN_SECONDS=1800 \
K_COMMS_LOAD_MAX_P95_MS=750 \
K_COMMS_LOAD_REQUIRE_ZERO_LOSS=true \
node scripts/staging_load.mjs
```

## Proposed local soak screen

This 15-minute, two-message-per-second profile screens for simple drift without
claiming long-duration or production-like soak coverage:

```bash
K_COMMS_LOAD_MESSAGES=1800 \
K_COMMS_LOAD_CONCURRENCY=6 \
K_COMMS_LOAD_DURATION_SECONDS=900 \
K_COMMS_LOAD_DUPLICATE_PROBES=20 \
K_COMMS_TIMEOUT_MS=5000 \
K_COMMS_LOAD_MAX_RUN_SECONDS=3600 \
K_COMMS_LOAD_MAX_P95_MS=750 \
K_COMMS_LOAD_REQUIRE_ZERO_LOSS=true \
node scripts/staging_load.mjs
```

## Result and gate semantics

The runner prints one aggregate `RESULT` JSON record containing:

- workload count, concurrency, duration, and duplicate probes;
- successful/failed attempts, error rate, elapsed time, and achieved rate;
- message-acceptance p50, p95, p99, minimum, and maximum latency;
- idempotency probe matches/failures;
- expected, found, lost, unexpected, duplicate, and ordering reconciliation;
- threshold decisions and cleanup status.

It never prints credentials, access/refresh tokens, message bodies, response
bodies, or signed URLs. An explicit `K_COMMS_LOAD_MAX_P95_MS` fails when p95 is
missing or above the threshold. `K_COMMS_LOAD_REQUIRE_ZERO_LOSS=true` fails on
any send failure or missing acknowledged message. Ordering, unexpected history,
duplicate history, idempotency, and cleanup violations fail independently.

## Evidence record

For each candidate, retain the aggregate `RESULT` line together with:

- UTC start/end timestamp;
- Git commit and dirty/clean state;
- immutable image digest;
- Podman/Kubernetes topology and replica counts;
- host CPU, memory, operating system, and competing workload notes;
- PostgreSQL/object-store placement and persistence mode;
- whether the quick qualification or soak profile ran.

After committing the candidate, building the exact revision-labeled image, and
deploying it, generate the canonical non-secret binding record with:

```bash
make release-evidence \
  IMAGE=localhost/k-comms:git-<commit> \
  RELEASE_EVIDENCE_NAMESPACE=k-comms-staging \
  RELEASE_EVIDENCE_OUTPUT=/approved/evidence/release-evidence.json \
  RELEASE_EVIDENCE_ARGS='--evidence load=/approved/evidence/load.log --evidence acceptance=/approved/evidence/acceptance.log'
```

The equivalent direct command is
`python scripts/collect_release_evidence.py --image IMAGE --namespace NAMESPACE
--output PATH`, with a repeated `--evidence LABEL=PATH` for each retained
regular file. The collector refuses a dirty tree by default, requires the
image's OCI revision label to equal Git `HEAD`, records only allow-listed image
and Kubernetes topology fields, hashes evidence without retaining its
contents, and rechecks Git state before atomically writing JSON. Never use
`--allow-dirty` for promotion evidence; that override is diagnostics-only and
is marked in the output.

Do not record a pass until the migrated candidate and temporary synthetic
credential have been used. Never copy a result from an older image or an
unknown tenant into release evidence.

## Production promotion binding and receipts

Staging evidence becomes a production input only after it is explicitly bound
to the exact reviewed production bundle, immutable image, Git revision, target
cluster, namespace, and observed controls. Keep the provider-composed bundle
and every receipt in an encrypted, access-controlled evidence directory; the
bundle can contain a rendered Secret even though the collector persists only
its SHA-256 and byte count.

First apply and review the exact production bundle, wait for its migration Job
and workloads, then create a **non-promotable** binding artifact:

```bash
python scripts/collect_release_evidence.py \
  --profile production \
  --image "$IMAGE_REPOSITORY@sha256:$IMAGE_DIGEST" \
  --namespace "$PRODUCTION_NAMESPACE" \
  --environment-id "$PRODUCTION_ENVIRONMENT_ID" \
  --production-bundle "$PRODUCTION_BUNDLE" \
  --binding-only \
  --output "$EVIDENCE_DIR/production-binding.json"
```

The command runs the production bundle semantic preflight before cluster
inspection. It then verifies the digest-pinned image and ready edge/worker
topology, hashes the observed cluster and namespace UIDs, and compares the
reviewed desired state with the live ConfigMap, edge and worker Deployments,
NetworkPolicies, PodDisruptionBudgets, HorizontalPodAutoscalers, and completed
migration Job. Deployment `.spec.replicas` is intentionally excluded because
the bound HPAs own that field; all other reviewed Deployment spec fields,
including container and pod security controls, remain bound. Kubernetes
`resourceVersion` is also excluded from the stable control hash. The binding
artifact has `promotion.mode: "binding"`, `promotion.promotion_ready: false`,
no receipts, and the values each receipt must copy from:

- `promotion.bundle.sha256`;
- `promotion.controls.live_sha256`;
- `promotion.environment`, including the environment ID, namespace, and
  SHA-256 hashes of the cluster and namespace UIDs;
- `source.git.revision` and `image.manifest_digest`.

Create one UTF-8 JSON receipt for every required type:

- `backup_restore`
- `failover`
- `migration`
- `production_preflight`
- `security`
- `staging_acceptance`
- `staging_load`
- `staging_product_acceptance`

Each receipt must be a stable regular file of at most 64 KiB, not a symlink,
with exactly this schema and no additional fields:

```json
{
  "bundle_sha256": "<promotion.bundle.sha256: 64 lowercase hex characters>",
  "completed_at": "2026-07-13T04:00:00Z",
  "environment": {
    "cluster_uid_sha256": "<64 lowercase hex characters>",
    "id": "<production environment ID>",
    "namespace": "<production namespace>",
    "namespace_uid_sha256": "<64 lowercase hex characters>"
  },
  "git_revision": "<40 lowercase hex characters>",
  "image_digest": "sha256:<64 lowercase hex characters>",
  "live_controls_sha256": "<promotion.controls.live_sha256: 64 lowercase hex characters>",
  "receipt_type": "migration",
  "schema_version": 1,
  "started_at": "2026-07-13T03:50:00Z",
  "status": "passed"
}
```

`receipt_type` must equal the type supplied on its `--receipt TYPE=PATH`
argument. All receipts must say `passed`, use the same binding values, have
`started_at <= completed_at <=` final collection time, and be no more than
seven days old. Retain the underlying logs or signed evidence separately; do
not add their contents or secret values to the receipt.

Run the final collection with all eight receipts:

```bash
python scripts/collect_release_evidence.py \
  --profile production \
  --image "$IMAGE_REPOSITORY@sha256:$IMAGE_DIGEST" \
  --namespace "$PRODUCTION_NAMESPACE" \
  --environment-id "$PRODUCTION_ENVIRONMENT_ID" \
  --production-bundle "$PRODUCTION_BUNDLE" \
  --receipt "backup_restore=$EVIDENCE_DIR/backup_restore.json" \
  --receipt "failover=$EVIDENCE_DIR/failover.json" \
  --receipt "migration=$EVIDENCE_DIR/migration.json" \
  --receipt "production_preflight=$EVIDENCE_DIR/production_preflight.json" \
  --receipt "security=$EVIDENCE_DIR/security.json" \
  --receipt "staging_acceptance=$EVIDENCE_DIR/staging_acceptance.json" \
  --receipt "staging_load=$EVIDENCE_DIR/staging_load.json" \
  --receipt "staging_product_acceptance=$EVIDENCE_DIR/staging_product_acceptance.json" \
  --output "$EVIDENCE_DIR/production-release-evidence.json"
```

The final run repeats bundle preflight and live inspection, rejects receipt
reuse after bundle, Git, image, environment, or control drift, and rechecks the
bundle, environment, live controls, and Git state before writing. Only an
artifact with `promotion.mode: "final"` and
`promotion.promotion_ready: true` is production promotion evidence.

## Historical 2026-07-12 qualification result

Revision `bc6ba02536b4bfb703cd5e196d2e431b690a24ad` passed the bounded local
qualification on a single-host Podman/kind cluster. These measurements are a
historical baseline, not evidence for a later commit. The application topology
was two edge replicas plus one worker replica; PostgreSQL and MinIO were local
persistent state for environment proof only.

| Measure | Result |
|---|---:|
| Attempted / successful / failed sends | 300 / 300 / 0 |
| Configured and achieved rate | 5 messages/second |
| p95 message-acceptance latency | 23.13 ms |
| p99 message-acceptance latency | 25.13 ms |
| Idempotency probes | 10 matched / 0 failed |
| History reconciliation | 300 found / 0 lost / 0 unexpected / 0 duplicate |
| Ordering | Passed |
| Synthetic cleanup | Passed |

The qualification evidence also includes a 25,000,000-byte attachment
ceiling; product acceptance; ready replacement of one edge pod and the worker
pod; restoration of the three-node Erlang cluster; rollback compatibility;
roll-forward product acceptance; and isolated PostgreSQL and MinIO
backup/restore verification. Static release evidence included 57 web unit
tests, 43 passed Playwright journeys plus three intentional per-project skips, 24 Node
runner tests, eight secret-validation tests, five production-manifest tests,
156 backend tests, clean Sobelow output, and strict validation of 76 Kubernetes
resources. All 23 GitHub Actions uses are commit-SHA pinned; Trivy filesystem
vulnerability/secret, rendered-IaC, and image gates plus CodeQL JavaScript/
TypeScript are present in CI. The independently sealed exact-commit Codex
Security result is separate publication evidence and is not claimed by this
qualification.

The guarded isolated restore proof used a quiesced current database/object
backup containing 18 attachment rows and 10 objects. It verified and remapped
four ready version-bound candidates, created five audit records, showed a
pre-backup message attachment in the restored UI, and returned it through an
authenticated version-bound download whose SHA-256 exactly matched. Six legacy
unversioned rows intentionally remained quarantined and fail-closed.

This historical result qualified that revision for a real staging environment.
It does not qualify the current tree and does not establish production
throughput, tail-latency SLOs, multi-zone headroom, provider readiness,
support/on-call readiness, or disaster-recovery targets. Those remain launch
gates and must be recorded against the immutable promoted artifact in the
target environment.
