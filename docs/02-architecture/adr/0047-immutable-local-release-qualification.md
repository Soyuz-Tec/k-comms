# ADR-0047: Qualify an immutable loopback-only local release

- **Status:** Accepted
- **Date:** 2026-07-24
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0008, ADR-0025, ADR-0045, ADR-0046
- **Related requirements:** WP-7 in the mobile communication experience delivery plan

## Context

The development Compose stack bind-mounts source, runs Phoenix in development
mode, and serves the React client through Vite. It is useful for feedback but
cannot prove that the Dockerfile `runtime` target contains the correct static
client, starts as a non-root OTP release, migrates correctly, or can restore
the previous application image.

The production runtime correctly requires HTTPS and WSS provider origins.
Local, same-host LiveKit qualification uses loopback HTTP and WebSocket ports,
so applying the normal production rule would either disable the media proof or
encourage a broad insecure exception.

## Decision

Add a separate `k-comms-release` Compose topology and one PowerShell operator
entry point. A deployment:

1. refuses a dirty worktree and tags the Dockerfile `runtime` target with the
   full Git SHA plus a unique attempt suffix, preserving earlier same-revision
   rollback targets;
2. records the OCI revision label, image ID/digest, exact environment, retained
   Compose source, rendered configuration, and hashes all three configuration
   inputs outside the repository;
3. starts isolated, digest-pinned PostgreSQL, MinIO, and LiveKit services with
   loopback-only host ports and no Vite or source mount;
4. runs `CommsCore.Release.migrate()` from the same candidate image before
   starting the packaged application;
5. waits for database, object storage, media, application readiness, packaged
   web UI, and audio/video capability checks; and
6. retains the previous image and configuration. Rollback uses that candidate's
   retained, hash-verified Compose source rather than the current checkout. A
   failed candidate restores the previous application automatically, and
   explicit rollback never runs a down migration.

The state directory is never adopted implicitly. The operator creates a
canonical-path and Compose-project ownership marker before applying its
current-user-only ACL. Existing unmarked directories, dangerous roots,
repository ancestors, and reparse points in any existing custom-path ancestor
fail before state is written or any ACL is mutated. The path is checked again
after directory creation and immediately before ACL hardening.
Deploy, Rollback, and Stop are serialized by both an exclusive state-file lock
and a Compose-project mutex. The first failed candidate stops and removes every
candidate container, verifies the project has no remaining containers, and
retains named data volumes and failure evidence. Status
distinguishes the recorded receipt from observed container health and image
identity.

The production runtime gains one fail-closed exception,
`K_COMMS_LOCAL_RELEASE=true`. It is valid only when
`ALLOW_DEVELOPMENT_ADAPTERS=true`, the runtime purpose is `application`,
LiveKit is enabled, every public application/object/media origin is an
explicit loopback HTTP/WS origin, and the internal LiveKit API is exactly
`http://livekit:7880`. One-shot migrations do not enable this exception.

This mode is local qualification only. Kubernetes staging and production
bundles continue to require their existing HTTPS/WSS, managed-state, provider,
attestation, and approval controls.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Rejection reason |
|---|---|---|---|
| Qualify the development Compose stack | No new assets | Source mounts and Vite do not test the release image | Cannot provide exact-image evidence |
| Disable calls in the packaged local stack | Avoids an exception | Omits the feature with the highest browser/provider risk | Does not satisfy media qualification |
| Commit a local TLS private key | Preserves HTTPS/WSS syntax | Creates key-handling and trust-store risk | Private keys and host trust do not belong in the repository |
| Permit arbitrary HTTP/WS origins when development adapters are enabled | Simple configuration | Could weaken a misconfigured shared environment | The exception must be explicit and loopback-only |
| Automatically run down migrations during rollback | Restores an older schema | Can destroy data and violates expand-contract rollback | Application rollback must preserve forward schema state |

## Consequences

### Positive

- The exact packaged UI and OTP release are exercised before staging.
- Development containers, ports, volumes, and Vite workflow remain untouched.
- A release receipt makes image/configuration identity and rollback target
  auditable.
- Same-revision retries cannot overwrite a retained predecessor image tag, and
  checkout changes cannot silently alter rollback topology.
- Local one-to-one and group media can be tested without weakening the normal
  production-origin contract.

### Negative and accepted trade-offs

- The local release uses separate PostgreSQL and MinIO volumes, so development
  data is not automatically present.
- HTTP/WS media proof does not qualify TURN/TLS, external certificates, managed
  providers, or remote clients.
- Retained environments contain local secrets and consume image/storage space.
- A custom state directory must either be newly created by the operator or
  already carry its matching ownership marker.

### Operational consequences

- Release state lives under `%LOCALAPPDATA%\K-Comms\local-release` with a
  current-user-only ACL.
- Schema changes must remain one-release backward compatible. Rollback restores
  code and configuration only.
- Operators use one script for validate, deploy, status, rollback, and stop.

### Security and privacy consequences

- The script rejects state directories inside the repository and never prints
  secrets.
- It also rejects unowned existing directories, dangerous roots, repository
  ancestors, and reparse points before changing ACLs.
- All published release ports are bound to `127.0.0.1`.
- The clear-text origin exception is rejected unless both gates and the exact
  local topology are present.

## Validation

- `mix test apps/comms_integrations/test/local_release_guard_test.exs --warnings-as-errors`
- `python scripts/test_validate_local_release.py`
- `python scripts/validate_local_release.py`
- PowerShell parser validation for `scripts/manage_local_release.ps1`
- `powershell -ExecutionPolicy Bypass -File scripts/manage_local_release.ps1 -Action Validate`
- State-root mutation tests for unowned directories, canonical marker mismatch,
  a normal child below a junction ancestor, dangerous roots, post-create
  revalidation, and concurrent operations
- Executable first-candidate failure cleanup tests covering all services and a
  fail-closed remaining-container observation
- A deployment receipt showing successful forward migration, healthy packaged
  application, revision-matching image labels, retained predecessor, and a
  rollback rehearsal without down migrations

## Revisit triggers

- Local qualification moves behind a trusted TLS ingress.
- LiveKit/TURN topology or browser secure-context requirements change.
- Podman Compose is replaced as the supported Windows local runtime.
- A migration is not one-release backward compatible.
