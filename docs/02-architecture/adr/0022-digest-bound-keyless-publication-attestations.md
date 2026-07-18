# ADR-0022: Publish digest-bound keyless provenance and SBOM attestations

**Status:** Accepted

## Context

K-Comms promotes one immutable container image through staging and production.
An image tag, downloaded SBOM, or successful build log alone does not prove that
the reviewed source, published registry object, and component inventory are the
same artifact. Long-lived signing keys would also add secret custody, rotation,
and recovery obligations that the project does not otherwise need.

## Decision

The main-branch publication workflow will build and smoke one image, publish it
under `sha-<full-commit-sha>`, and capture the registry's immutable manifest
digest. The same workflow will:

- generate and retain a CycloneDX JSON SBOM from that exact local image;
- create GitHub artifact build-provenance and SBOM attestations for the same
  fully qualified GHCR repository and registry digest; and
- use GitHub Actions OIDC and Sigstore's keyless certificate flow rather than a
  repository-managed signing key.

Promotion consumes the digest, never a mutable tag or rebuilt image. It must
verify both predicates against `Soyuz-Tec/k-comms/.github/workflows/container.yml`
and confirm that the image OCI revision and version labels match the selected
commit. A retained, unsigned SBOM remains useful inventory evidence but cannot
substitute for the digest-bound SBOM attestation.

The runtime image also carries that build revision in
`K_COMMS_RELEASE_REVISION`. The protected content-blind operations snapshot
exposes only the validated full revision so operator runbook links resolve to
the matching repository tree. Development runtimes without exact build
metadata expose `development` and do not render a clickable runbook link.

## Consequences

- Publication requires GitHub `id-token`, `attestations`, and package-write
  permissions, scoped only to the publication job.
- Promotion stops if either attestation is absent or bound to another digest or
  workflow identity.
- The raw CycloneDX artifact remains available for component, vulnerability,
  and license review without becoming an independent trust root.
- Registry and GitHub artifact retention are operational dependencies; disaster
  recovery must preserve the selected digest and verification receipts.
- A future publication platform must provide an equivalent short-lived identity
  and predicate-verification contract or explicitly supersede this ADR.

## Alternatives considered

- **Trust a commit-derived image tag:** rejected because tags can move and do
  not cryptographically bind publication to the reviewed workflow.
- **Retain only an unsigned SBOM:** rejected because file location and checksum
  do not bind it to the registry manifest or workflow identity.
- **Manage a cosign private key:** rejected because it adds a long-lived secret
  and rotation boundary without improving the current GitHub-hosted workflow.
- **Rebuild separately for SBOM generation:** rejected because a second build
  could describe bytes different from the promoted image.

## Validation

The publication workflow must smoke the exact image before pushing it, validate
that the CycloneDX document has identity fields and components, retain the raw
SBOM, and create both attestations against the captured registry digest. Release
qualification verifies the provenance predicate, the CycloneDX predicate, the
signer workflow, and the image OCI labels before promotion. The detailed command
contract is maintained in
`docs/10-infrastructure-and-deployment/supply-chain-integrity.md`.
