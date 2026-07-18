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
gh attestation verify "oci://${image}@${digest}" \
  --repo Soyuz-Tec/k-comms \
  --signer-workflow Soyuz-Tec/k-comms/.github/workflows/container.yml
gh attestation verify "oci://${image}@${digest}" \
  --repo Soyuz-Tec/k-comms \
  --signer-workflow Soyuz-Tec/k-comms/.github/workflows/container.yml \
  --predicate-type https://cyclonedx.org/bom
```

The first command verifies the default SLSA build-provenance predicate; the
second verifies the CycloneDX SBOM predicate. Both attestations bind the same
registry digest to `Soyuz-Tec/k-comms` and are signed with the short-lived
Sigstore certificate obtained through GitHub Actions OIDC. K-Comms therefore
does not add a second long-lived cosign key or an unrelated signature: the
GitHub artifact attestations are the keyless, verifiable signature boundary.

Before promotion, verify that the image's OCI `source`, `revision`, and
`version` labels match the repository, commit, and `sha-<full-commit-sha>` tag.
Never promote a mutable tag or a locally rebuilt image between environments.
Retain the workflow's `k-comms-sbom-<full-commit-sha>` artifact for review, but
treat successful digest-bound attestation verification—not possession of an
unverified downloaded JSON file—as the promotion control.
