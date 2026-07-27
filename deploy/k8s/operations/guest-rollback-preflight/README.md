# Communication rollback preflight

This one-shot operation is the mandatory compatibility gate before applying an
older K-Comms application bundle. It runs from the **currently deployed image**
after edge and worker writers have been quiesced. It never runs migration
rollback and never mutates guest, instant-room, bounded join-receipt,
presence-lease, or identity data. The retained directory name is stable for
existing operator automation.

The target is communication-compatible only when both its edge and worker pod
templates carry the exact identical annotation:

```text
k-comms.soyuz-tec.io/rollback-capabilities: guest_identity_v1,guest_admission_expiry_worker_v1,instant_room_lifecycle_v1,instant_room_presence_lease_v1,instant_room_expiry_worker_v1,conversation_only_human_v1
```

Missing, partial, unknown, or different annotations classify the target as
legacy. For a legacy target, the release operation requires an exclusive
database client and evaluates each state hazard against the target capability
that owns it. It fails when unsupported persisted guest users, conversation-only
human users, instant rooms, bounded join receipts, presence leases, or available,
scheduled, executing, or retryable guest/instant-room lifecycle Jobs exist.
Instant-room rows and their bounded join receipts are both owned by
`instant_room_lifecycle_v1`. A blocked target must be replaced with an approved
compatible bridge, or the incident must roll forward.

## Render and execute

Set `CURRENT_BUNDLE` to the exact approved bundle presently deployed and
`TARGET_BUNDLE` to the exact older bundle under consideration. Both must already
have passed their environment's normal checksum and semantic validation.

```bash
set -euo pipefail
export NAMESPACE='<k-comms-staging or k-comms-production>'
export CURRENT_BUNDLE='<restricted path to current approved bundle>'
export TARGET_BUNDLE='<restricted path to target approved bundle>'
test -r "$CURRENT_BUNDLE"
test -r "$TARGET_BUNDLE"

# Record and verify the currently deployed edge/worker image before quiescing.
CURRENT_EDGE_IMAGE="$(kubectl -n "$NAMESPACE" get deployment/k-comms-edge \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
CURRENT_WORKER_IMAGE="$(kubectl -n "$NAMESPACE" get deployment/k-comms-worker \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
test "$CURRENT_EDGE_IMAGE" = "$CURRENT_WORKER_IMAGE"
printf '%s' "$CURRENT_EDGE_IMAGE" |
  grep -Eq '^.+@sha256:[0-9a-f]{64}$'

# Read only target workload metadata. Never print or retain Secret documents.
IFS=$'\t' read -r TARGET_IMAGE TARGET_REVISION TARGET_CAPABILITIES < <(
  python - "$TARGET_BUNDLE" <<'PY'
import re
import sys
import yaml

path = sys.argv[1]
documents = [
    item for item in yaml.safe_load_all(open(path, encoding="utf-8"))
    if isinstance(item, dict)
]
names = ("k-comms-edge", "k-comms-worker")
deployments = {}
for name in names:
    matches = [
        item for item in documents
        if item.get("kind") == "Deployment"
        and item.get("metadata", {}).get("name") == name
    ]
    if len(matches) != 1:
        raise SystemExit(f"target must contain exactly one Deployment {name}")
    deployments[name] = matches[0]

images = [
    deployments[name]["spec"]["template"]["spec"]["containers"][0]["image"]
    for name in names
]
if len(set(images)) != 1 or not re.fullmatch(r".+@sha256:[0-9a-f]{64}", images[0]):
    raise SystemExit("target edge and worker must use one exact immutable image")

key = "k-comms.soyuz-tec.io/rollback-capabilities"
expected = (
    "guest_identity_v1,guest_admission_expiry_worker_v1,"
    "instant_room_lifecycle_v1,instant_room_presence_lease_v1,"
    "instant_room_expiry_worker_v1,conversation_only_human_v1"
)
values = [
    deployments[name]["spec"]["template"]
    .get("metadata", {}).get("annotations", {}).get(key)
    for name in names
]
capabilities = expected if values == [expected, expected] else ""
revision = images[0].rsplit("@sha256:", 1)[1]
print(images[0], revision, capabilities, sep="\t")
PY
)
test -n "$TARGET_IMAGE"
test -n "$TARGET_REVISION"

# Production HPAs must be deleted before scale-down or their minReplicas can
# reactivate writers. --ignore-not-found also makes this safe in staging.
kubectl -n "$NAMESPACE" get hpa/k-comms-edge hpa/k-comms-worker -o yaml \
  > '<restricted evidence path>/pre-rollback-hpas.yaml' 2>/dev/null || true
kubectl -n "$NAMESPACE" delete hpa/k-comms-edge hpa/k-comms-worker \
  --ignore-not-found
kubectl -n "$NAMESPACE" scale deployment/k-comms-edge \
  deployment/k-comms-worker --replicas=0
kubectl -n "$NAMESPACE" wait --for=delete pod \
  -l app.kubernetes.io/component=edge --timeout=10m
kubectl -n "$NAMESPACE" wait --for=delete pod \
  -l app.kubernetes.io/component=worker --timeout=10m
test -z "$(kubectl -n "$NAMESPACE" get pods \
  -l app.kubernetes.io/component=edge -o name)"
test -z "$(kubectl -n "$NAMESPACE" get pods \
  -l app.kubernetes.io/component=worker -o name)"

OPERATION_BUNDLE="$(mktemp)"
chmod 0600 "$OPERATION_BUNDLE"
cleanup_operation() { rm -f "$OPERATION_BUNDLE"; }
trap cleanup_operation EXIT
kustomize build deploy/k8s/operations/guest-rollback-preflight |
  kubectl set image --local -f - \
    "guest-rollback-preflight=$CURRENT_EDGE_IMAGE" -o yaml |
  kubectl set env --local -f - --containers=guest-rollback-preflight \
    "K_COMMS_ROLLBACK_TARGET_CAPABILITIES=$TARGET_CAPABILITIES" \
    "K_COMMS_ROLLBACK_TARGET_REVISION=$TARGET_REVISION" \
    K_COMMS_ROLLBACK_WRITES_QUIESCED=true -o yaml > "$OPERATION_BUNDLE"

kubectl -n "$NAMESPACE" delete job/k-comms-guest-rollback-preflight \
  --ignore-not-found
kubectl -n "$NAMESPACE" apply -f "$OPERATION_BUNDLE"
if ! kubectl -n "$NAMESPACE" wait --for=condition=complete \
  job/k-comms-guest-rollback-preflight --timeout=5m; then
  kubectl -n "$NAMESPACE" describe job/k-comms-guest-rollback-preflight
  kubectl -n "$NAMESPACE" logs job/k-comms-guest-rollback-preflight \
    --all-containers=true || true
  kubectl apply --server-side -f "$CURRENT_BUNDLE" \
    -l 'app.kubernetes.io/component notin (migration,minio-init,runtime-secrets)'
  kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=10m
  kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=10m
  echo "Rollback target blocked; current approved application restored." >&2
  exit 1
fi
kubectl -n "$NAMESPACE" logs job/k-comms-guest-rollback-preflight
```

For production, pass the rendered operation beside `CURRENT_BUNDLE` to
`scripts/validate_production_bundle.py` before applying it. A successful Job
authorizes only the exact `TARGET_REVISION` recorded in its environment and
logs; apply no other target. If target activation fails, reapply
`CURRENT_BUNDLE`, wait for both Deployments and HPAs, rerun smoke tests, and
retain only content-free Job status, aggregate hazard counts, image digests,
checksums, and timestamps.
