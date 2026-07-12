# Runtime

Production orchestrator selection is an ADR gate. Keep runtime assets portable until approved.

## Immutable GHCR artifact

Use the `Container` workflow summary to copy the published `sha256` digest. The
`sha-<full-commit-sha>` tag is traceability metadata; deployments must pin the
digest returned by the registry:

```bash
image=ghcr.io/soyuz-tec/k-comms
digest=sha256:<digest-from-the-container-workflow>
docker pull "${image}@${digest}"
gh attestation verify "oci://${image}@${digest}" --repo Soyuz-Tec/k-comms
```

Before promotion, verify that the image's OCI `source`, `revision`, and
`version` labels match the repository, commit, and `sha-<full-commit-sha>` tag.
Never promote a mutable tag or a locally rebuilt image between environments.
