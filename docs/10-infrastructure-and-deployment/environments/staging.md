# Staging Environment

The repository contains a portable staging package under
`deploy/k8s/overlays/staging`. Package validation proves that the manifests
render and that the image can build and boot locally. It does **not** prove that
a particular cluster, ingress controller, certificate, storage class, DNS
zone, or backup system is ready.

## Package-ready evidence

Run these gates from the repository root:

```bash
make validation-deps
make contracts docs-check
make compose-validate
make kube-validate
make IMAGE=localhost/k-comms:staging container-smoke
```

The package is ready only when those commands pass for the exact commit and
image digest being promoted.

## Environment-specific deployment gates

Keep these unchecked until verified against the target cluster:

- [ ] Namespace access and deployment authority approved
- [ ] Immutable image digest is available to every node
- [ ] Default storage class and requested volume sizes approved
- [ ] Ingress class `nginx` exists, or the overlay has been adapted
- [ ] DNS names resolve to the staging ingress
- [ ] TLS secret `k-comms-staging-tls` contains the approved certificate chain
- [ ] Runtime and bootstrap env files contain no empty or `CHANGE_ME` values
- [ ] The rendered staging ConfigMap is applied before MinIO starts
- [ ] HTTP bootstrap remains disabled and the one-time release bootstrap succeeds
- [ ] The ephemeral bootstrap Secret and local env file are deleted afterward
- [ ] Real runtime secrets are supplied outside Git, rotation-tested, and followed by explicit rollout restarts
- [ ] PostgreSQL and MinIO isolated backup/restore evidence and checksums are retained
- [ ] The ingress accepts an attachment at the 25,000,000-byte application limit
- [ ] Current and previous approved rendered bundles are retained in restricted storage
- [ ] Alert routes and log retention are tested
- [ ] Migration, rollout, synthetic smoke, rollback, and roll-forward exercises pass

Exact configure, migration, deploy, smoke, and rollback commands are maintained
in `deploy/k8s/overlays/staging/README.md`.

## Local executable proof

`deploy/k8s/overlays/local-proof` exercises the package on kind with local DNS,
a short-lived CA, ingress, persistent PostgreSQL and MinIO, secret rotation,
isolated restores, and rollback/roll-forward acceptance. Its acceptance Job
uses the full 25,000,000-byte attachment allowance. This is concrete runtime
evidence for the portable package; it does not substitute for managed-cluster
authority, public DNS/certificates, external alert routing, or multi-node
failure testing in the selected staging environment.
