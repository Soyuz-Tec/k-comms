# Definition of Ready and Done

## Ready

- Requirement and user/business outcome are clear.
- Dependencies and architecture decisions are identified.
- Security, data, and reliability implications are assessed.
- Acceptance tests and telemetry are defined.
- Rollout and compatibility constraints are understood.

## Done

- Code, tests, schemas, documentation, and telemetry are merged.
- Security and architecture checks pass.
- Migration and rollback are rehearsed where applicable.
- Dashboards/alerts/runbooks are updated.
- Feature is deployed safely and acceptance evidence is recorded.
- The applicable exit state in the
  [development-to-production completion standard](../14-operations/development-to-production-completion-standard.md)
  is reached.
- Runtime changes use the same attested digest in staging and production, with
  verified backup, rollback, receipt, health, and reconciliation evidence.
- The delivery branch and worktree are finalized and the exact merge/deployment
  identifiers are recorded.
