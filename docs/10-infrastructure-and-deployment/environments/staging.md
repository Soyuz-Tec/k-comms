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
- [ ] Real secrets are supplied outside Git and have been rotation-tested
- [ ] PostgreSQL and MinIO backup/restore evidence is retained
- [ ] Alert routes and log retention are tested
- [ ] Migration, rollout, synthetic smoke, and rollback exercises pass

Exact configure, migration, deploy, smoke, and rollback commands are maintained
in `deploy/k8s/overlays/staging/README.md`.
