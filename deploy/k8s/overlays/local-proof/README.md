# Local Kubernetes staging proof

This overlay runs the staging package unchanged except for local hostnames and
an image loaded directly into a kind node. It is for environment-gate evidence,
not a production topology.

The overlay deliberately keeps the media provider disabled and deploys neither
LiveKit nor TURN. The repository's loopback Compose stack is the same-host
functional proof for one-to-one/group audio/video and screen sharing. A passing
local-proof overlay therefore does not claim media readiness, external
WSS/HTTPS or TURN/TLS reachability, group/bandwidth capacity, or privacy and
incident-response approval.

- Kubernetes: kind v0.32 with the pinned Kubernetes 1.34 node image
- Ingress: the final ingress-nginx kind manifest used only for this local proof
- Public-style hosts: `comms.k-comms.test` and `objects.k-comms.test`
- Host ports: HTTP `8084`, HTTPS `8444`
- TLS: a short-lived local CA and leaf certificate stored only in the cluster

Use `curl --resolve` (or an equivalent test-client resolver) for host-side
health checks when the local resolver does not already map the `.test` names.
The browser-visible origin includes host port `8444`, so add the same port to
the ingress controller Service before running the in-cluster acceptance Job:

```bash
if test "$(kubectl -n ingress-nginx get service ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="https-local-proof")].port}')" != "8444"; then
  kubectl -n ingress-nginx patch service ingress-nginx-controller --type=json \
    -p='[{"op":"add","path":"/spec/ports/-","value":{"appProtocol":"https","name":"https-local-proof","port":8444,"protocol":"TCP","targetPort":"https"}}]'
fi
```

A temporary CoreDNS mapping resolves both names to that Service. The
certificate must include both hostnames and every test client must trust the
temporary CA. Never commit the CA, leaf key, generated staging secrets,
rendered bundles, credentials, or database/object dumps.

The deployment, backup, migration, acceptance, rollback, and restore sequence
is the same as the staging runbook in `../staging/README.md`.

For the baseline in-cluster acceptance pass, create
`k-comms-qualification-scripts` from `scripts/staging_acceptance.mjs`,
`scripts/staging_product_acceptance.mjs`, and `scripts/staging_load.mjs`, and
create `k-comms-local-ca` from the temporary CA certificate. Then apply
`acceptance-job.yaml`. The Job reads the temporary
synthetic credential from `k-comms-qualification`; it must never read the
release-bootstrap Secret. Delete `k-comms-bootstrap` immediately after the
idempotent bootstrap Job succeeds. The acceptance pass exercises the configured
25,000,000-byte application attachment ceiling through ingress as well as
authentication, realtime delivery, replay, object verification, logout, and
revocation. Retain `k-comms-qualification` only through the planned acceptance,
rollback, and roll-forward reruns, then delete it together with the temporary
runner ConfigMap and NetworkPolicy.

Run `scripts/staging_product_acceptance.mjs` and `scripts/staging_load.mjs`
through equivalent temporary Node Jobs using the same CA and credential
mounts. They may instead run from the host against
`https://comms.k-comms.test:8444` when the host resolver maps both `.test`
names to `127.0.0.1`. Those runners create, reconcile, and clean only
UUID-scoped synthetic data.

## Historical completed local proof

Revision `bc6ba02536b4bfb703cd5e196d2e431b690a24ad` completed the local
environment gate on 2026-07-12 with two edge replicas and one worker replica.
The proof included:

- the 25,000,000-byte attachment path through ingress;
- product acceptance and a 300-message load run with zero failed sends, zero
  lost or duplicate history records, ten matching idempotency probes, an
  achieved rate of 5 messages/second, p95 23.13 ms, and p99 25.13 ms;
- deletion and ready replacement of one edge pod and the worker pod, followed
  by a healthy three-node Erlang cluster;
- rollback to the retained release, compatibility smoke, roll-forward to the
  candidate, and post-forward product acceptance; and
- isolated PostgreSQL and MinIO backup/restore verification.

These results qualify only that exact revision as a historical local-staging
baseline. Every newer candidate must repeat the gate and produce
revision-bound evidence. Local proof does not replace production provider,
managed-state, multi-zone capacity, security review, or on-call readiness
gates.
