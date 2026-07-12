# K-Comms staging runbook

This overlay is a portable staging package. It deliberately uses one
PostgreSQL pod and one MinIO pod; production must replace them with approved
data services. Run every command from the repository root.

## 1. Configure and render

```bash
export OVERLAY=deploy/k8s/overlays/staging
export NAMESPACE=k-comms-staging
export IMAGE_DIGEST='<sha256 digest from the promoted OCI image>'

cp "$OVERLAY/secrets.env.example" "$OVERLAY/secrets.env"
$EDITOR "$OVERLAY/secrets.env"

# Use standalone Kustomize v5 to pin the promoted immutable image locally.
(cd "$OVERLAY" && kustomize edit set image \
  "ghcr.io/soyuz-tec/k-comms=ghcr.io/soyuz-tec/k-comms@sha256:${IMAGE_DIGEST}")

kubectl kustomize "$OVERLAY" > /tmp/k-comms-staging.yaml
kubectl apply --dry-run=client --validate=false -f /tmp/k-comms-staging.yaml >/dev/null
```

Review `/tmp/k-comms-staging.yaml` without copying its generated Secret into
logs or tickets. Confirm the ingress hosts, TLS secret name, storage requests,
and image digest before continuing.

## 2. Provision data services

Apply the namespace and the generated secret first, then start the portable
staging data services. Network policies are applied with the final bundle after
the migration completes.

```bash
kubectl apply -f "$OVERLAY/namespace.yaml"

kubectl -n "$NAMESPACE" create secret generic k-comms-secrets \
  --from-env-file="$OVERLAY/secrets.env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" apply \
  -f deploy/k8s/base/service-account.yaml \
  -f deploy/k8s/base/configmap.yaml \
  -f "$OVERLAY/postgres-service.yaml" \
  -f "$OVERLAY/postgres-statefulset.yaml" \
  -f "$OVERLAY/minio-service.yaml" \
  -f "$OVERLAY/minio-statefulset.yaml"

kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=5m
kubectl -n "$NAMESPACE" rollout status statefulset/minio --timeout=5m

kubectl -n "$NAMESPACE" delete job minio-init --ignore-not-found
kubectl apply -k "$OVERLAY" -l app.kubernetes.io/component=minio-init
kubectl -n "$NAMESPACE" wait --for=condition=complete job/minio-init --timeout=5m
```

## 3. Back up and migrate

Take a pre-deploy database backup before every migration. Delete the prior Job
because Kubernetes Job pod templates are immutable.

```bash
kubectl -n "$NAMESPACE" exec postgres-0 -- \
  sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "k-comms-staging-predeploy-$(date -u +%Y%m%dT%H%M%SZ).dump"

kubectl -n "$NAMESPACE" delete job k-comms-migrate --ignore-not-found
kubectl apply -k "$OVERLAY" -l app.kubernetes.io/component=migration
kubectl -n "$NAMESPACE" wait --for=condition=complete job/k-comms-migrate --timeout=10m
kubectl -n "$NAMESPACE" logs job/k-comms-migrate
```

Do not deploy application pods if the migration Job fails.

## 4. Deploy

```bash
kubectl apply --server-side -k "$OVERLAY"
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=10m
kubectl -n "$NAMESPACE" get pods,svc,ingress,pdb
```

Provision `k-comms-staging-tls` and staging DNS before testing the public hosts.
The ingress controller namespace should replace the broad port-only ingress
allow rules with cluster-specific namespace and pod selectors where supported.

## 5. Smoke test

First verify the services from inside the namespace, then verify the public TLS
paths and WebSocket upgrade behavior from outside the cluster.

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

Retain command output, image digest, migration logs, and timestamps as staging
evidence. Authentication, message send/replay, attachment upload/download, and
session revocation must also be exercised through the client before promotion.

## 6. Roll back

Application rollback is safe only while migrations remain backward-compatible.
Set both deployments back to the previously approved immutable image and watch
the rollout:

```bash
export PREVIOUS_IMAGE='ghcr.io/soyuz-tec/k-comms@sha256:<previous digest>'

kubectl -n "$NAMESPACE" set image deployment/k-comms-edge \
  "edge=$PREVIOUS_IMAGE"
kubectl -n "$NAMESPACE" set image deployment/k-comms-worker \
  "worker=$PREVIOUS_IMAGE"
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-edge --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/k-comms-worker --timeout=10m
kubectl -n "$NAMESPACE" get pods
```

Repeat the smoke commands after rollback. Do not automatically run a down
migration. If the release is not backward-compatible, stop the rollout, obtain
database-owner approval, scale application deployments to zero, and restore the
retained pre-deploy backup using the documented PostgreSQL restore procedure.

## Cleanup of local secret material

```bash
rm -f "$OVERLAY/secrets.env" /tmp/k-comms-staging.yaml
```
