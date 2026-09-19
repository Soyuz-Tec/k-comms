# ADR-0082: Isolate container service environments

- **Status:** Accepted
- **Date:** 2026-09-19
- **Owners:** Operations, Security
- **Related decisions:** ADR-0055, ADR-0058, ADR-0080

## Context

The Proxmox application and all three sidecars load the entire protected host
`runtime.env`. Consequently, a database, storage, or media process receives
application signing, encryption, provider, and bootstrap credentials it does
not use. One-shot storage administration also receives the full configuration.
Changing a Quadlet alone does not update the environment of an active container.

## Decision

Keep `runtime.env` as the root-owned host source and backup format. Generate
explicit allowlists for the application, PostgreSQL, MinIO, LiveKit, storage
administration, and bootstrap. Never source or evaluate this file. Reject
unknown inputs, duplicate assignments, placeholders, malformed records, missing
essential values, insecure ownership/permissions, and symbolic-link sources.
Adding a runtime setting requires an explicit ownership decision covered by CI.

The generated directory and each generation are root-owned mode `0700`; files
are mode `0600`. Write a complete generation before atomically replacing its
`current` pointer. Failed preparation leaves the previous generation active.
Remove the preceding generation after publication; backups and deployment
guards continue to retain configuration under their existing restricted policy.
The source and derived values are never printed, and container inspection
failures identify a service/control only.

Install, asset synchronization, deployment, rollback, restoration, and legacy
adoption regenerate restricted files. Python 3 is an explicit installer
dependency. An existing host without it fails synchronization before activation;
install the reviewed dependency through the normal host-maintenance process.

After quiescence and backup, deployment inspects each running sidecar and
restarts only those whose environment differs. Before success, it checks all
four running containers against the restricted source. Application migration
and rollback checks use application values; the storage client receives only
its administrator credentials and bucket name. Bootstrap values are injected
only into the explicitly requested synthetic staging bootstrap command.

Failure recovery preserves ADR-0080. A deployment that fails while transitioning
from the old bundle may restore its previous application unit, including that
older unit's environment scope. Recovery restores availability without claiming
the isolation upgrade succeeded; the failed release remains blocked. A
successful new deployment must pass inspection of all running environments.

## Consequences

Compromising a sidecar no longer exposes unrelated application secrets through
its environment. This does not separate the application's database role, rotate
credentials, reduce the privileges of an existing shared credential, or protect
against host root. If S3 application values equal MinIO administrator values,
their privileges remain equal until a separately qualified credential change.

Operators edit the protected source and deploy the reviewed change; generated
files are not another configuration authority. A new unsupported provider key
blocks deployment until classified. A source restored from backup regenerates
the derived files; they do not need separate backup or manual editing.

## Alternatives

- A denylist leaks newly added secrets by default. Explicit ownership fails closed.
- Four independently overwritten files can publish a partially updated set.
  A complete generation and atomic pointer give one configuration boundary.
- Secret rotation or an external secret manager changes credential authority
  and host integration; those require their own qualification and are not
  prerequisites for removing this specific cross-service disclosure.

## Validation

Linux tests cover exact ownership, literal values, malformed/duplicate/unknown
inputs, permissions, links, partial publication failure, rotation cleanup,
container leakage and stale values. The real deployment script is exercised
with synthetic commands to verify backup-before-sidecar-transition ordering,
restricted one-shot inputs, failed transition recovery, and final inspection
failure recovery. CI also detects new unclassified runtime inputs and rejects
shared host environment use in Quadlets and one-shot commands.

Protected staging must verify the actual containers before production approval.
These local tests do not constitute a live host configuration change.
