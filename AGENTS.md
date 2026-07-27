# K-Comms Agent Instructions

Follow the global working agreements and the nearest repository documentation.
Repository files, tests, GitHub state, deployment receipts, and live runtime
evidence override conversational history.

## Required completion standard

After implementing a completed development change or feature update, follow
[the development-to-production completion standard](docs/14-operations/development-to-production-completion-standard.md)
without waiting for another instruction.

- Continue through local verification, commit, push, pull request, required
  checks, protected merge, and final evidence.
- For a completed runtime, infrastructure, configuration, migration, or
  security change, continue through immutable artifact publication and
  protected staging qualification.
- Then continue through production approval, backup, deployment of the same digest,
  post-deployment verification, and finalization.
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
