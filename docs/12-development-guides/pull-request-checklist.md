# Pull Request Checklist

This is a per-pull-request template. Unchecked boxes here do not represent the
state of a release; completed evidence belongs in the pull request and the
release control/qualification records.

Every pull request must classify the change and apply the applicable gates in
the [development-to-production completion standard](../14-operations/development-to-production-completion-standard.md).

- [ ] Requirement or issue linked
- [ ] Design/ADR linked where material
- [ ] Architecture manifest or baseline changes include the required immutable-base transition declaration, validator tests, and ADR
- [ ] Tests cover success, failure, retry, and authorization
- [ ] Interface schemas updated
- [ ] Migration is backward compatible and rehearsable
- [ ] Telemetry and runbook impact considered
- [ ] Security and privacy checklist completed
- [ ] GitHub Actions use an approved action repository and a full commit SHA
- [ ] Any scanner exception is resource-specific, expiring, and protected by a negative control
- [ ] Rollout and rollback plan included
- [ ] Approved rendered bundle, secret rotation/restart, and backup restore evidence addressed for deployment changes
- [ ] Runtime changes identify the immutable digest and link staging qualification
- [ ] Production-impacting changes link approval, backup, receipt, health, reconciliation, and rollback evidence
- [ ] Final merge SHA and clean handoff state recorded
