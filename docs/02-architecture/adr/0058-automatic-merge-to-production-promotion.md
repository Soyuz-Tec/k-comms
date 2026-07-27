# ADR-0058: Automate protected merge-to-production promotion

- **Status:** Accepted
- **Date:** 2026-07-27
- **Owners:** Delivery, Operations, Architecture, and Security
- **Related decisions:** ADR-0012, ADR-0022, ADR-0047, ADR-0055, ADR-0057

## Context

K-Comms already had protected source delivery, immutable GHCR publication,
digest-bound provenance and SBOM attestations, protected Proxmox environments,
host-side backups, verification, rollback, restore, and receipts. The remaining
release path was operator-coordinated: after publication, staging and production
were submitted as separate manual workflow runs, and staging rollback/restore
rehearsal was not part of one enforceable pipeline.

That gap made a completed runtime change depend on another instruction to copy
the digest and start each environment. It also allowed the written completion
standard to be stronger than the executable workflow.

## Decision

The `Container` workflow is the release orchestrator for runtime-impacting
merges to protected `main`.

1. Build, smoke, publish, and attest one immutable image.
2. Expose only the full digest reference and exact source revision as job
   outputs.
3. Call the reusable protected Proxmox deployment workflow for staging.
4. On staging, deploy the candidate, retain the pre-deploy backup, rehearse
   rollback to the preceding release, reactivate the exact candidate, and
   restore the PostgreSQL and MinIO backup into isolated rehearsal targets.
5. Queue the same digest for the protected production environment.
6. Wait for the required production reviewer. The workflow does not approve or
   bypass its own deployment.
7. After approval, re-confirm the revision is still the current protected
   `main`, verify the running release, create the quiesced backup, deploy the
   same digest, retain non-secret evidence, and verify the public application,
   media, and object-storage endpoints.

The direct `Deploy Proxmox` workflow remains available through
`workflow_dispatch` for reviewed recovery and explicitly requested operations.
It is also callable through `workflow_call`; it is never triggered by an
untrusted pull request or a direct push on its own.

Runtime-impact classification includes application code, web code, container
definitions, the Proxmox package, remote deployment wrappers, release
validators, and the two governing workflows. Documentation-only and
governance-only merges remain non-deploying.

Main release runs are serialized and are not cancelled by a later merge. A
later source revision causes an older candidate to fail the protected-main
recheck before host access rather than silently deploying stale code.

## Consequences

Every runtime-impacting protected merge automatically advances as far as the
repository's safety controls permit. A person no longer copies digests or
starts staging and production forms manually. The only normal human pause is
the independent production approval required by the protected environment.

Staging qualification now produces machine-readable deployment, rollback,
restore-rehearsal, and aggregate qualification receipts. Each environment also
exports a non-secret workflow evidence artifact retained with the release run.

The automated restore rehearsal does not replace authoritative staging data. It
restores PostgreSQL into a temporary database and extracts the MinIO archive
into a temporary directory, validates both, then removes the rehearsal targets.
Production restore remains a separate explicitly confirmed operation.

The release remains fail-closed. A failed check, attestation, staging
qualification, backup, approval, protected-main recheck, deployment, receipt,
or public health check prevents later jobs from running.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Continue manually dispatching both environments | The digest-copy and submission steps were unnecessary operational gaps. |
| Remove production approval | It weakens the existing protected-environment control and is not authorized. |
| Rebuild separately for staging and production | It breaks immutable same-digest promotion and supply-chain evidence. |
| Use `workflow_run` with a privileged checkout | A same-workflow reusable call avoids a second privileged trigger and keeps the called workflow at the protected merge revision. |
| Destructively restore the active staging database for every release | An isolated database and archive rehearsal proves recoverability without interrupting the qualified candidate. |

## Validation

- The Proxmox validator requires the complete publication-to-production job
  graph, reusable protected deployment workflow, staging qualification,
  isolated restore, evidence export, serialized release behavior, and public
  verification.
- Regression tests reject removal of `workflow_call`, staging dependency,
  non-cancelling main releases, and isolated restore receipts.
- PowerShell parsing and strict Bash syntax checks cover all new wrappers and
  host scripts.
- A completed release is proven by one workflow run containing the publication,
  staging, production, public verification, and retained evidence artifacts.

## Revisit triggers

- A custom automated production protection rule replaces human approval.
- Deployment moves away from the dedicated Proxmox VMs.
- A second production origin enables canary or blue/green traffic shifting.
- Independent backup storage or PostgreSQL PITR changes recovery evidence.
