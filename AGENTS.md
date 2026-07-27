# K-Comms Agent Instructions

Follow the global working agreements and the nearest repository documentation.
Repository files, tests, GitHub state, deployment receipts, and live runtime
evidence override conversational history.

## Canonical development workspace

On the managed Windows workstation, the standard K-Comms development workspace
is:

`C:\Users\vasan\OneDrive\Documents\k-comms`

- Treat that checkout as the default location for active development.
- Use local/containerized dependencies with synthetic data only.
- Do not treat Proxmox VM 101 (staging) or VM 100 (production) as a
  development environment.
- Temporary Git worktrees are allowed for isolated delivery or recovery work,
  but they do not replace the canonical workspace.
- Before removing a temporary worktree, prove it has no uncommitted files and
  that every unique commit is merged or retained on a remote branch.
- Remove clean temporary worktrees after their work is merged or safely
  retained. Do not create independent duplicate clones such as `k-comms 2`.
- Never remove a dirty or uniquely committed workspace; consolidate or publish
  its work first.

## Required completion standard

After implementing a completed development change or feature update, follow
[the development-to-production completion standard](docs/14-operations/development-to-production-completion-standard.md)
without waiting for another instruction.

- Continue through local verification, commit, push, pull request, required
  checks, protected merge, and final evidence.
- For a completed runtime, infrastructure, configuration, migration, or
  security change, continue through immutable artifact publication and
  protected staging qualification.
- Then continue through production approval and backup.
- Complete deployment of the same digest, post-deployment verification, and
  finalization.
- Runtime-impacting merges automatically enter the serialized Container release
  chain. Do not ask for another deployment instruction or manually rebuild the
  image between environments.
- Continue automatically through staging and queue production. The protected
  production approval remains an independent authorized-reviewer action and
  must never be self-approved or bypassed by the implementing agent.
- For documentation-only or governance-only work, finish at a protected merge
  after documentation checks; do not create or deploy a runtime artifact.
- Do not bypass a required check, protected environment, attestation, backup,
  rollback, restore, migration, security, or runtime-health gate.
- Stop only when the user explicitly limits the work to local/draft/staging,
  an external approval must be performed by an authorized reviewer, or a gate
  fails and cannot be corrected safely within scope.

The standard is the default authorization to perform routine, in-scope,
reversible completion steps. It does not authorize destructive data changes,
secret disclosure, protection bypasses, or unrelated work.
