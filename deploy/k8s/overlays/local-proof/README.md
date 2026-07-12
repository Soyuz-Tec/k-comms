# Local Kubernetes staging proof

This overlay runs the staging package unchanged except for local hostnames and
an image loaded directly into a kind node. It is for environment-gate evidence,
not a production topology.

- Kubernetes: kind v0.32 with the pinned Kubernetes 1.34 node image
- Ingress: the final ingress-nginx kind manifest used only for this local proof
- Public-style hosts: `comms.k-comms.test` and `objects.k-comms.test`
- Host ports: HTTP `8084`, HTTPS `8444`
- TLS: a short-lived local CA and leaf certificate stored only in the cluster

Use `curl --resolve` (or an equivalent test-client resolver) for host-side
health checks because editing the Windows hosts file requires administrator
access. Full acceptance runs inside the cluster, where a temporary CoreDNS
mapping resolves both names to the ingress service on standard HTTPS port 443.
The certificate must include both hostnames and the client must trust the
temporary CA. Never commit the CA, leaf key, generated staging secrets,
rendered bundles, or database/object dumps.

The deployment, backup, migration, acceptance, rollback, and restore sequence
is the same as the staging runbook in `../staging/README.md`.

For the full in-cluster acceptance pass, create `k-comms-acceptance-script`
from `scripts/staging_acceptance.mjs` and `k-comms-local-ca` from the temporary
CA certificate, then apply `acceptance-job.yaml`. The Job reads the short-lived
bootstrap credentials from `k-comms-bootstrap`. It exercises the configured
25,000,000-byte application attachment ceiling through ingress as well as
authentication, realtime delivery, replay, object verification, logout, and
revocation. Retain the bootstrap Secret only through any planned rollback and
roll-forward acceptance reruns, then delete it immediately.
