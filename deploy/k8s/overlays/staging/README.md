# K-Comms staging runbook

This overlay is a portable staging package. It deliberately uses one
PostgreSQL pod and one MinIO pod; production must replace them with approved
data services. Run every command from the repository root in a controlled
deployment shell.

The portable staging overlay keeps AUDIO_PROVIDER_MODE=disabled and does not
deploy LiveKit or TURN. This is accepted only through staging's explicit
`ALLOW_DEVELOPMENT_ADAPTERS=true` gate; production cannot use that exemption.
Local same-host audio/video and screen sharing are qualified by Compose. An
environment-specific staging composition may enable LiveKit only when it adds
an externally managed WSS origin, the matching exact CSP source, validated
provider credentials, WSS/HTTPS and TURN/TLS network evidence, group/bandwidth
capacity limits, privacy approval, and the audio/video/screen journeys described
by the production provider contract. Keep
AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS at the maintained 660-second
minimum repeat horizon unless the composed environment is qualifying another
production-valid 660-1,800 second value. The horizon must not be shorter than
the participant-token lifetime. Failed removal attempts remain durable after
the horizon until one succeeds at or after it. A green
portable staging run therefore does not claim audio or video readiness.

## 1. Configure, validate, and render

Use an immutable promoted image digest. The evidence directory must be
encrypted, access-controlled, and outside the repository because the rendered
application bundle contains a Kubernetes Secret.

```bash
set -euo pipefail
export OVERLAY=deploy/k8s/overlays/staging
export NAMESPACE=k-comms-staging
export IMAGE_DIGEST='<64 hexadecimal characters, without the sha256: prefix>'
export EVIDENCE_DIR='<encrypted restricted deployment artifact directory>'

cp "$OVERLAY/secrets.env.example" "$OVERLAY/secrets.env"
cp "$OVERLAY/bootstrap-secrets.env.example" "$OVERLAY/bootstrap-secrets.env"
$EDITOR "$OVERLAY/secrets.env" "$OVERLAY/bootstrap-secrets.env"

python scripts/validate_staging_secrets.py \
  "$OVERLAY/secrets.env" "$OVERLAY/bootstrap-secrets.env"

test "${#IMAGE_DIGEST}" -eq 64
printf '%s' "$IMAGE_DIGEST" | grep -Eq '^[0-9a-f]{64}$'
install -d -m 0700 "$EVIDENCE_DIR"
umask 077

# Copy the complete Kustomize tree so relative bases still resolve, then pin the
# disposable copy. Never run `kustomize edit` against the tracked repository.
export RENDER_ROOT="$(mktemp -d)"
chmod 0700 "$RENDER_ROOT"
cleanup_render() { rm -rf "$RENDER_ROOT"; }
trap cleanup_render EXIT
cp -R deploy/k8s "$RENDER_ROOT/k8s"
chmod -R go-rwx "$RENDER_ROOT"
export RENDER_OVERLAY="$RENDER_ROOT/k8s/overlays/staging"

# Use standalone Kustomize v5 to pin both release Jobs and workloads.
for kustomization in "$RENDER_OVERLAY" "$RENDER_OVERLAY/bootstrap"; do
  (cd "$kustomization" && kustomize edit set image \
    "ghcr.io/soyuz-tec/k-comms=ghcr.io/soyuz-tec/k-comms@sha256:${IMAGE_DIGEST}")
done

export APPROVED_BUNDLE="$EVIDENCE_DIR/k-comms-staging-${IMAGE_DIGEST}.yaml"
export BOOTSTRAP_BUNDLE="$EVIDENCE_DIR/k-comms-bootstrap-${IMAGE_DIGEST}.yaml"
kustomize build "$RENDER_OVERLAY" > "$APPROVED_BUNDLE"
kustomize build "$RENDER_OVERLAY/bootstrap" > "$BOOTSTRAP_BUNDLE"
chmod 0600 "$APPROVED_BUNDLE" "$BOOTSTRAP_BUNDLE"
sha256sum "$APPROVED_BUNDLE" "$BOOTSTRAP_BUNDLE" > \
  "$EVIDENCE_DIR/rendered-bundles-${IMAGE_DIGEST}.sha256"

kubectl apply --dry-run=client --validate=false -f "$APPROVED_BUNDLE" >/dev/null
kubectl apply --dry-run=client --validate=false -f "$BOOTSTRAP_BUNDLE" >/dev/null
cleanup_render
trap - EXIT
```

The validator rejects empty values and every `CHANGE_ME` placeholder before
the first cluster write. Review the bundles without copying their Secret data
into logs or tickets. Confirm ingress hosts, TLS secret name, storage requests,
the `32m` ingress budget for the 25,000,000-byte application limit, and the
image digest. Retain the
approved bundle and checksum in the restricted deployment evidence store; it
is the desired-state artifact used by the rollback procedure.

## 2. Provision configuration and data services

Apply the namespace, runtime secret, service account, and the **rendered overlay
ConfigMap** before starting data services. This ordering is required because
MinIO reads the staging-specific CORS origin from that ConfigMap. Network
policies are applied with the approved bundle after migration.

```bash
kubectl apply -f "$OVERLAY/namespace.yaml"

kubectl -n "$NAMESPACE" create secret generic k-comms-secrets \
  --from-env-file="$OVERLAY/secrets.env" \
  --dry-run=client -o yaml | kubectl apply --server-side -f -

kubectl -n "$NAMESPACE" apply -f deploy/k8s/base/service-account.yaml
kubectl apply --server-side -f "$APPROVED_BUNDLE" \
  -l app.kubernetes.io/component=configuration

test "$(kubectl -n "$NAMESPACE" get configmap k-comms-config \
  -o jsonpath='{.data.ALLOW_BOOTSTRAP}')" = "false"

kubectl -n "$NAMESPACE" apply \
  -f "$OVERLAY/postgres-service.yaml" \
  -f "$OVERLAY/postgres-statefulset.yaml" \
  -f "$OVERLAY/minio-service.yaml" \
  -f "$OVERLAY/minio-statefulset.yaml"

kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=5m
kubectl -n "$NAMESPACE" rollout status statefulset/minio --timeout=5m

kubectl -n "$NAMESPACE" delete job minio-init --ignore-not-found
kubectl apply -f "$APPROVED_BUNDLE" \
  -l app.kubernetes.io/component=minio-init
kubectl -n "$NAMESPACE" wait --for=condition=complete job/minio-init --timeout=5m
```

## 3. Back up and verify restore capability

Take both backups before every migration. Retain their checksums and restore
evidence. Run this in a staging maintenance window so the evidence describes a
stable pre-deploy point.

### PostgreSQL logical backup and isolated restore verification

The restore target is a temporary database. These commands never overwrite the
active database.

```bash
export BACKUP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export DB_BACKUP="$EVIDENCE_DIR/k-comms-staging-predeploy-${BACKUP_STAMP}.dump"
export VERIFY_DB="k_comms_restore_verify_$(date -u +%Y%m%d%H%M%S)"

kubectl -n "$NAMESPACE" exec postgres-0 -- sh -lc '
  rm -f /tmp/k-comms-predeploy.dump
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc \
    -f /tmp/k-comms-predeploy.dump
  pg_restore --list /tmp/k-comms-predeploy.dump >/dev/null
'
kubectl -n "$NAMESPACE" cp \
  postgres-0:/tmp/k-comms-predeploy.dump "$DB_BACKUP"
test -s "$DB_BACKUP"
sha256sum "$DB_BACKUP" | tee "$DB_BACKUP.sha256"

kubectl -n "$NAMESPACE" cp \
  "$DB_BACKUP" postgres-0:/tmp/k-comms-restore-verify.dump
cleanup_postgres_verify() {
  kubectl -n "$NAMESPACE" exec postgres-0 -- env VERIFY_DB="$VERIFY_DB" sh -lc '
    dropdb -U "$POSTGRES_USER" --if-exists "$VERIFY_DB"
    rm -f /tmp/k-comms-predeploy.dump /tmp/k-comms-restore-verify.dump
  ' >/dev/null 2>&1 || true
}
trap cleanup_postgres_verify EXIT
kubectl -n "$NAMESPACE" exec postgres-0 -- env VERIFY_DB="$VERIFY_DB" sh -lc '
  dropdb -U "$POSTGRES_USER" --if-exists "$VERIFY_DB"
  createdb -U "$POSTGRES_USER" "$VERIFY_DB"
  pg_restore --exit-on-error --no-owner --no-privileges \
    -U "$POSTGRES_USER" -d "$VERIFY_DB" /tmp/k-comms-restore-verify.dump
  psql -U "$POSTGRES_USER" -d "$VERIFY_DB" -v ON_ERROR_STOP=1 -At <<SQL
SELECT current_database();
SELECT count(*) FROM tenants;
SELECT count(*) FROM users;
SELECT count(*) FROM conversations;
SELECT count(*) FROM messages;
SELECT count(*) FROM attachments;
SQL
' | tee "$EVIDENCE_DIR/postgres-restore-verify-${BACKUP_STAMP}.txt"
cleanup_postgres_verify
trap - EXIT
```

The evidence must show a successful `pg_restore --exit-on-error`, all five
authoritative tables, and no cleanup error. A restore test on the same
PostgreSQL instance proves logical recoverability only; production also
requires an independent backup location and point-in-time recovery rehearsal.

### MinIO object backup and isolated restore verification

Install the pinned-compatible `mc` client on the deployment workstation. The
procedure mirrors the staging bucket to restricted storage, restores it to a
temporary bucket, downloads that bucket, and compares SHA-256 manifests. It
does not alter the live bucket.

```bash
export S3_BUCKET="$(kubectl -n "$NAMESPACE" get configmap k-comms-config \
  -o jsonpath='{.data.S3_BUCKET}')"
export MINIO_BACKUP_DIR="$EVIDENCE_DIR/minio-${S3_BUCKET}-${BACKUP_STAMP}"
export MINIO_VERIFY_DIR="$(mktemp -d)"
export MINIO_VERIFY_BUCKET="${S3_BUCKET}-restore-verify-$(date -u +%s)"
export MC_CONFIG_DIR="$(mktemp -d)"
chmod 0700 "$MC_CONFIG_DIR" "$MINIO_VERIFY_DIR"
mkdir -m 0700 "$MINIO_BACKUP_DIR"

MINIO_USER="$(kubectl -n "$NAMESPACE" get secret k-comms-secrets \
  -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 --decode)"
MINIO_PASSWORD="$(kubectl -n "$NAMESPACE" get secret k-comms-secrets \
  -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 --decode)"

kubectl -n "$NAMESPACE" port-forward service/minio 19000:9000 \
  >"$EVIDENCE_DIR/minio-port-forward-${BACKUP_STAMP}.log" 2>&1 &
MINIO_PORT_FORWARD_PID=$!
cleanup_minio_verify() {
  mc rb --force "staging/$MINIO_VERIFY_BUCKET" >/dev/null 2>&1 || true
  kill "$MINIO_PORT_FORWARD_PID" 2>/dev/null || true
  rm -rf "$MC_CONFIG_DIR" "$MINIO_VERIFY_DIR" /tmp/k-comms-minio-restore.sha256
  unset MINIO_USER MINIO_PASSWORD
}
trap cleanup_minio_verify EXIT
sleep 2

mc alias set staging http://127.0.0.1:19000 "$MINIO_USER" "$MINIO_PASSWORD"
mc mirror --overwrite --preserve "staging/$S3_BUCKET/" "$MINIO_BACKUP_DIR/"
(cd "$MINIO_BACKUP_DIR" && find . -type f -print0 | sort -z | \
  xargs -0 -r sha256sum) > "$EVIDENCE_DIR/minio-${S3_BUCKET}-${BACKUP_STAMP}.sha256"

mc mb "staging/$MINIO_VERIFY_BUCKET"
mc mirror --overwrite --preserve "$MINIO_BACKUP_DIR/" \
  "staging/$MINIO_VERIFY_BUCKET/"
test -z "$(mc diff "$MINIO_BACKUP_DIR/" "staging/$MINIO_VERIFY_BUCKET/")"
mc mirror --overwrite --preserve "staging/$MINIO_VERIFY_BUCKET/" \
  "$MINIO_VERIFY_DIR/"
(cd "$MINIO_VERIFY_DIR" && find . -type f -print0 | sort -z | \
  xargs -0 -r sha256sum) > /tmp/k-comms-minio-restore.sha256
diff "$EVIDENCE_DIR/minio-${S3_BUCKET}-${BACKUP_STAMP}.sha256" \
  /tmp/k-comms-minio-restore.sha256
cleanup_minio_verify
trap - EXIT
```

The approved manifest remains the backup for portable bucket configuration.
Object versioning is enabled by the staging MinIO initialization Job. Extend
this procedure when retention, replication, IAM, or lifecycle policies change;
a plain mirror covers current object data, not those service-level policies or
historical object versions.

The embedded staging MinIO has a bounded 2 GiB `/tmp` workspace. Keep that
capacity above the 1 GiB maximum tenant attachment policy so multipart writes
and portable restore verification cannot evict the pod solely because of the
temporary-volume limit. Production uses the externally managed object-store
contract instead of this single-node staging StatefulSet.

### Restoring mirrored attachment objects safely

`mc mirror` restores object bytes but assigns new version IDs. K-Comms pins
downloads and scanner reads to the version ID recorded in PostgreSQL, so a
database restored beside a mirrored bucket must not be exposed to application
traffic until those IDs are reconciled. A volume snapshot of the complete
MinIO data directory can preserve MinIO's internal version metadata locally,
but it is storage-layout-dependent and is not the portable backup described
above. Production should prefer provider-native, version-aware replication or
snapshots. For the portable staging proof, use the guarded remap below.

This is an actual restore/rehearsal sequence, not part of every pre-deploy
backup verification:

1. Keep edge and worker deployments scaled to zero. Restore PostgreSQL into a
   new database and create a new empty MinIO bucket.
2. Enable versioning on the new bucket **before** mirroring objects into it.
   Restore the approved backup directory, then repeat the SHA-256 manifest
   comparison from the isolated verification procedure.
3. Point `k-comms-secrets` at the new database and point `k-comms-config` at
   the new bucket. Run the current release's migration Job against the restored
   database while application deployments remain stopped.
4. Run the one-shot attachment version remap with the same immutable image that
   will run the restored application. Do not start application pods if it
   fails.
5. Start the restored application and complete the existing-attachment smoke
   described below before accepting traffic.

The one-shot operation HEADs each current object, requires the restored byte
size, compares normalized ETags when they are trustworthy content MD5 values,
then streams the exact returned version through SHA-256. Its checksum must
equal `verified_checksum_sha256` and that verified checksum must still equal
the attachment's declared checksum. It obtains the replacement version ID
from the S3 response. Every candidate must verify before one PostgreSQL
transaction locks the candidate rows, remaps changed IDs, and writes per-file
and per-tenant audit events. A missing object, changed byte count, trustworthy
ETag mismatch, checksum mismatch, missing version response, or concurrent row
change aborts without a partial database remap. Opaque or encrypted-provider
ETags are reported as untrusted and never substitute for the streamed SHA-256
proof.

Prepare the short-lived audit context outside the repository from
`deploy/k8s/operations/attachment-restore-remap/restore-remap-context.env.example`.
Use a new UUID for every attempt and an approved operator identity and reason.
The confirmation value is fixed in the reviewed Job and the release function
also refuses to run unless `K_COMMS_RUNTIME_PURPOSE=one_shot`.

```bash
export RESTORE_OPERATION=deploy/k8s/operations/attachment-restore-remap
export RESTORE_CONTEXT="$EVIDENCE_DIR/restore-remap-context-${BACKUP_STAMP}.env"
export RESTORE_IMAGE='<approved immutable image digest>'
export RESTORE_JOB_BUNDLE="$EVIDENCE_DIR/restore-remap-job-${BACKUP_STAMP}.yaml"

test -s "$RESTORE_CONTEXT"
chmod 0600 "$RESTORE_CONTEXT"
! grep -q 'CHANGE_ME' "$RESTORE_CONTEXT"
grep -Eq '^OPERATION_ID=[0-9a-fA-F-]{36}$' "$RESTORE_CONTEXT"
grep -Eq '^ACTOR=.+$' "$RESTORE_CONTEXT"
grep -Eq '^REASON=.+$' "$RESTORE_CONTEXT"

kubectl -n "$NAMESPACE" create secret generic k-comms-restore-remap \
  --from-env-file="$RESTORE_CONTEXT" --dry-run=client -o yaml | \
  kubectl apply --server-side -f -
kubectl -n "$NAMESPACE" delete job k-comms-attachment-restore-remap \
  --ignore-not-found
kubectl set image --local \
  -f "$RESTORE_OPERATION/restore-remap-job.yaml" \
  restore-remap="$RESTORE_IMAGE" -o yaml > "$RESTORE_JOB_BUNDLE"
chmod 0600 "$RESTORE_JOB_BUNDLE"
kubectl -n "$NAMESPACE" apply --server-side -f "$RESTORE_JOB_BUNDLE"

if ! kubectl -n "$NAMESPACE" wait --for=condition=complete \
  job/k-comms-attachment-restore-remap --timeout=60m; then
  kubectl -n "$NAMESPACE" logs job/k-comms-attachment-restore-remap || true
  kubectl -n "$NAMESPACE" delete secret k-comms-restore-remap --ignore-not-found
  rm -f "$RESTORE_CONTEXT"
  exit 1
fi

kubectl -n "$NAMESPACE" logs job/k-comms-attachment-restore-remap | \
  tee "$EVIDENCE_DIR/attachment-restore-remap-${BACKUP_STAMP}.txt"
kubectl -n "$NAMESPACE" delete secret k-comms-restore-remap
rm -f "$RESTORE_CONTEXT"
```

The log contains aggregate counts only. Retain it with the Job bundle checksum
and confirm `attachment.restore_version_remapped` and
`attachment.restore_version_remap_completed` events in the restored audit
ledger. Investigate every nonzero `unversioned_fail_closed` count; such rows
remain non-downloadable and are never guessed or remapped.

After the Job succeeds, deploy the restored app but keep ingress out of normal
service. Select at least one attachment that was `ready` and `clean` before the
backup. Through an authenticated user session in the restored application:

1. Open the original message/file and request `GET /api/v1/attachments/:id`.
2. Confirm a version-bound download descriptor is returned. Do not copy its
   signed URL into logs or tickets.
3. Download through that descriptor and compare the downloaded bytes' SHA-256
   with the same row's `verified_checksum_sha256` in the restored database.
4. Confirm the file opens through the user interface and the audit summary
   carries the restore operation ID.

A newly uploaded file is not a substitute for this smoke: it must exercise an
attachment that crossed the database-and-object restore boundary. Only after
this integrated check and the normal authenticated smoke suite pass may ingress
return to service.

## 4. Migrate and run the one-time bootstrap

Delete the prior migration Job because Kubernetes Job pod templates are
immutable. Do not deploy application pods if migration fails.

```bash
kubectl -n "$NAMESPACE" delete job k-comms-migrate --ignore-not-found
kubectl apply -f "$APPROVED_BUNDLE" \
  -l app.kubernetes.io/component=migration
kubectl -n "$NAMESPACE" wait --for=condition=complete \
  job/k-comms-migrate --timeout=10m
kubectl -n "$NAMESPACE" logs job/k-comms-migrate
```

The initial owner is created by a release Job, never by the staging HTTP API.
The database operation is serialized and idempotent for the same normalized
tenant slug and owner email. A different identity fails closed after the first
tenant exists. The Job creates no browser session or plaintext credential
record.

```bash
kubectl -n "$NAMESPACE" create secret generic k-comms-bootstrap \
  --from-env-file="$OVERLAY/bootstrap-secrets.env" \
  --dry-run=client -o yaml | kubectl apply --server-side -f -
kubectl -n "$NAMESPACE" delete job k-comms-bootstrap --ignore-not-found
kubectl apply --server-side -f "$BOOTSTRAP_BUNDLE"

if ! kubectl -n "$NAMESPACE" wait --for=condition=complete \
  job/k-comms-bootstrap --timeout=10m; then
  kubectl -n "$NAMESPACE" logs job/k-comms-bootstrap || true
  kubectl -n "$NAMESPACE" delete secret k-comms-bootstrap --ignore-not-found
  rm -f "$OVERLAY/bootstrap-secrets.env"
  exit 1
fi

kubectl -n "$NAMESPACE" logs job/k-comms-bootstrap
kubectl -n "$NAMESPACE" delete secret k-comms-bootstrap
rm -f "$OVERLAY/bootstrap-secrets.env"
```

Never add the bootstrap Secret to the main Kustomize overlay. Delete it and its
local env file after every success or failure; owner password rotation happens
through the application, not by rerunning bootstrap with a new password.

## 5. Deploy

Apply the exact reviewed bundle, not a fresh unreviewed render.

```bash
kubectl apply --server-side -f "$APPROVED_BUNDLE"
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=10m
kubectl -n "$NAMESPACE" get pods,svc,ingress,pdb
```

Provision `k-comms-staging-tls` and staging DNS before testing public hosts.
The ingress controller namespace should replace broad port-only ingress allow
rules with cluster-specific namespace and pod selectors where supported.

## 6. Smoke test

Verify services inside the namespace, then public TLS paths and WebSocket
upgrade behavior from outside the cluster.

```bash
kubectl -n "$NAMESPACE" run k-comms-smoke --rm -i --restart=Never \
  --image=docker.io/curlimages/curl:8.14.1 -- \
  curl --fail --silent --show-error http://k-comms-edge/health/ready

kubectl -n "$NAMESPACE" run minio-smoke --rm -i --restart=Never \
  --image=docker.io/curlimages/curl:8.14.1 -- \
  curl --fail --silent --show-error http://minio:9000/minio/health/ready

curl --fail --silent --show-error \
  https://comms.staging.example.invalid/health/ready
curl --fail --silent --show-error \
  https://comms.staging.example.invalid/app/index.html >/dev/null
curl --fail --silent --show-error \
  https://objects.staging.example.invalid/minio/health/ready
```

Retain command output, rendered-bundle checksum, image digest, backup/restore
evidence, migration logs, and timestamps. Authentication, message send/replay,
an attachment near the 25,000,000-byte limit, download, and session revocation
must also be exercised through the client before promotion.

For any provider-composed audio/video staging run, retain a content-free receipt
that
proves participant admissions persist only the opaque identity and
authorization bindings, never the JWT. During an induced LiveKit outage,
membership/session revocation must commit and block new joins while durable
eviction stays queued. After recovery, prove retry plus repeated self-hosted
removal through at least the configured enforcement horizon, including a
synthetic cached-token reconnect attempt and a successful removal at or after
the horizon. Failures must remain queued beyond it. Record aggregate times and
attempt counts only;
exclude room names, participant identities, user identifiers, tokens, and
audio/video/screen content. Also prove two-party bidirectional camera media,
three-or-more participant group state, screen-share publish/subscribe/cleanup,
and source-restricted grants. This is bounded eviction evidence, not a claim of
LiveKit Cloud token revocation.

Set the environment documented by `node scripts/staging_acceptance.mjs --help`,
then capture the result of `node scripts/staging_acceptance.mjs` as smoke evidence.

Next run `node scripts/staging_product_acceptance.mjs` with the same run-scoped
credential environment. It qualifies invitation and second-user lifecycle,
public channels, disconnect replay, inactive-conversation activity, mentions,
threads, in-app state, browser-push intent delivery, service accounts,
content-blind platform operations, bounded audit export, and two 12-socket
reconnect waves. A successful run also verifies bounded cleanup of only its
UUID-scoped synthetic resources. Never retain its credential environment or
one-time values in logs.

After functional acceptance, set the credential environment documented by
`node scripts/staging_load.mjs --help` and run the proposed bounded local or
staging qualification profile from
`docs/07-capacity-and-performance/local-staging-qualification.md`. Retain only
the aggregate `RESULT` line plus commit, image digest, topology, host resources,
and timestamp. Do not retain shell history or output containing credential
environment values. This runner creates and archives its own private
conversation; it never deletes existing tenant data.

## 7. Rotate runtime secrets

`disableNameSuffixHash: true` keeps stable Secret names, so updating the Secret
does **not** restart pods. Coordinate provider-side password/key changes first,
validate the env file again, update the Secret, and explicitly restart every
consumer. Rotating `SECRET_KEY_BASE` invalidates sessions; rotating
`RELEASE_COOKIE` temporarily prevents old and new nodes from clustering, so do
both only in an approved maintenance window. Rotating
`PASSWORD_RECOVERY_SIGNING_KEY` invalidates every outstanding recovery link.
Platform-role management secrets must never be added to `secrets.env` or the
edge/worker environments. Render the restricted Job in
`deploy/k8s/operations/platform-role`, create its short-lived Secret from
`platform-role-secrets.env.example`, and replace its fail-closed image token
with the exact immutable digest already deployed to staging (the same
`kubectl set image --local` pattern used by the restore Job above). Run it,
verify the audit record, and delete both resources immediately. Never apply the
inventory manifest with its placeholder image.

```bash
python scripts/validate_staging_secrets.py "$OVERLAY/secrets.env"
kubectl -n "$NAMESPACE" create secret generic k-comms-secrets \
  --from-env-file="$OVERLAY/secrets.env" \
  --dry-run=client -o yaml | kubectl apply --server-side -f -
kubectl -n "$NAMESPACE" rollout restart \
  deployment/k-comms-edge deployment/k-comms-worker
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=10m
```

Re-render, review, checksum, and replace the restricted approved bundle after
every secret rotation so future reconciliation uses the current approved
secret revision. PostgreSQL and MinIO credential changes additionally require
their service-specific rotation sequence; do not restart those StatefulSets
until the old and new credentials have been coordinated and tested.

## 8. Roll back and drill safely

An application rollback is safe only while migrations remain compatible with
the previous release. Keep the prior approved rendered bundle and its checksum
in the restricted evidence store. Do not run down migrations automatically and
do not restore a database merely to test application rollback.

```bash
export PREVIOUS_RENDERED_BUNDLE='<restricted path to prior approved bundle>'
test -r "$PREVIOUS_RENDERED_BUNDLE"
sha256sum --check '<restricted path to prior bundle checksum file>'

# Exclude immutable one-shot Jobs and runtime Secrets. Current credentials stay
# active; the prior long-lived workload/configuration becomes desired state.
kubectl apply --server-side -f "$PREVIOUS_RENDERED_BUNDLE" \
  -l 'app.kubernetes.io/component notin (migration,minio-init,runtime-secrets)'
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=10m
kubectl -n "$NAMESPACE" get deployment/k-comms-edge deployment/k-comms-worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

Repeat all smoke tests after rollback. This reapplication step matters: a
one-off `kubectl set image` leaves cluster desired state different from the
approved artifact and is not an acceptable completed rollback.

For a scheduled rollback drill:

1. Confirm one-release schema compatibility and an on-call owner.
2. Record current bundle/image checksums and verify both database and MinIO
   restore evidence from section 3.
3. Apply the previous bundle with the exclusion selector above and run the full
   smoke suite.
4. Reapply the current `APPROVED_BUNDLE` with the same exclusion selector,
   wait for both deployments, and rerun the smoke suite.
5. Confirm `ALLOW_BOOTSTRAP=false`, current image digests, no failed Jobs, and
   no temporary restore database/bucket remain.
6. Record rollback and roll-forward times. Never delete PVCs, restore over the
   active database, or rotate credentials during a routine rollback drill.

If the previous application is not schema-compatible, stop the rollout and
obtain database-owner and incident-commander approval. Scale edge and worker to
zero, preserve a new backup of the failed state, restore the retained backup
into a **new** database, validate it with the section 3 procedure, update the
runtime Secret to the approved replacement `DATABASE_URL`, regenerate the
approved bundle, and only then deploy. Never overwrite the only active database
or delete its PVC as a shortcut.

## 9. Cleanup local secret material

The bootstrap secret should already be gone. After storing runtime values in
the approved secret manager and securing the rendered evidence, remove local
env files and confirm the ephemeral cluster Secret is absent.

```bash
kubectl -n "$NAMESPACE" delete secret k-comms-bootstrap --ignore-not-found
rm -f "$OVERLAY/secrets.env" "$OVERLAY/bootstrap-secrets.env"
```
