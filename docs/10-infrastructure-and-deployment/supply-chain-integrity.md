# Supply-Chain Integrity

## Publication contract

Pull requests build and smoke a local image without registry credentials. A
push to `main`, or an explicitly authorized `workflow_dispatch` with `main`
selected as its run ref, publishes one image to
`ghcr.io/soyuz-tec/k-comms:sha-<full-commit-sha>` and records the registry's
immutable `sha256` manifest digest. A manual run against any other branch or
tag skips publication. Environment manifests promote that digest, never the
mutable tag or a rebuilt image.

The publication job uses the reviewed, digest-pinned Trivy container to produce
a CycloneDX JSON SBOM from the image it just built and pushed. The raw SBOM is
retained as the `k-comms-sbom-<full-commit-sha>` workflow artifact for inventory
and review. GitHub then creates two in-toto attestations for the same fully
qualified image name and registry digest:

1. SLSA build provenance from `actions/attest-build-provenance`.
2. The CycloneDX predicate from `actions/attest-sbom`.

Both actions use GitHub Actions OIDC to obtain a short-lived Sigstore signing
certificate. The resulting artifact attestations are verifiable signatures
bound to the workflow identity and image digest. K-Comms intentionally does not
introduce a second long-lived cosign key or claim that an unverified SBOM file
alone signs the image.

## Required verification

Authenticate the GitHub CLI and container client to GHCR, copy the digest from
the successful `Container` workflow summary, and verify both predicates:

```bash
image=ghcr.io/soyuz-tec/k-comms
digest=sha256:<registry-digest>
signer=Soyuz-Tec/k-comms/.github/workflows/container.yml

docker pull "${image}@${digest}"
gh attestation verify "oci://${image}@${digest}" \
  --repo Soyuz-Tec/k-comms \
  --signer-workflow "${signer}"
gh attestation verify "oci://${image}@${digest}" \
  --repo Soyuz-Tec/k-comms \
  --signer-workflow "${signer}" \
  --predicate-type https://cyclonedx.org/bom
```

The default GitHub CLI predicate is SLSA provenance. The explicit CycloneDX
predicate check prevents a valid provenance attestation from being mistaken for
SBOM evidence. `--repo` and `--signer-workflow` constrain the certificate
identity to this repository and its publication workflow.

Promotion stops when either verification fails, the two checks target different
digests, the digest is absent from the reviewed deployment bundle, or the OCI
`source`, `revision`, and `version` labels do not match the selected commit and
tag. Retain the verification output or release-system receipt with the exact
production bundle; do not paste registry tokens or attestation credentials into
the receipt.

## Review and incident use

Download the workflow SBOM only from the exact publication run. Use it for
component inventory, vulnerability response, and license review, and compare
its SHA-256 with the workflow summary when retaining a copy. For promotion and
incident provenance, retrieve and verify the signed predicate by digest rather
than trusting the downloaded JSON by location or filename.
