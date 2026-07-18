# ADR-0044: Retrospectively accept the full PR #16 endgame scope

- **Status:** Accepted
- **Date:** 2026-07-18
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0001, ADR-0035, ADR-0042, ADR-0043

## Context

The Calls completion evidence correctly describes commit `ecf77da` as a
70-file Calls tranche with 3,945 insertions, 1,089 deletions, and no database
migration. Pull request #16 merged more than that tranche, however. Merge
commit `f304ebd` joined first parent `edb0b20` to reviewed head `6e60a54`.
That first-parent-to-reviewed-head delta contains 25 commits, 707 files,
109,896 insertions, 2,843 deletions, and 20 new migrations.

The full delta includes the staged product foundation, release and security
controls, production-hardening work, the non-audio modularization program, the
Calls tranche, and final mainline/container alignment. Calling the merged pull
request Calls-only would make its review and rollback posture inaccurate.

Every migration and the broader file and commit distribution were inspected.
The detailed evidence, ownership classification, and data-migration cautions
are recorded in
`docs/02-architecture/modular-monolith-endgame-merge-acceptance.md`.

## Decision

Accept the complete PR #16 delta as the integrated modular-monolith endgame,
not as a Calls-only change. ADR-0043 and the Calls completion record remain the
authoritative description of `ecf77da` only.

The repository integration is accepted because the resulting architecture is
strict and internally consistent: the current manifest governs 173 production
`CommsCore` modules, declares 38 uniquely owned table entries, and the
architecture analyzer and immutable empty baseline report zero findings.
Acceptance does not waive deployment controls for the 20 migrations.

Production promotion of this delta requires a forward-migration plan, a tested
database backup and restore path, migration preflight, and post-migration
smoke verification. Operators must not use migration `down/0` functions as the
general data rollback mechanism: several migrations intentionally delete or
transform state that `down/0` cannot restore, including legacy webhook secrets,
service-account and push-subscription records, governance records, and
participant/call state. Application rollback compatibility remains limited to
the explicitly documented one-release session path.

`20260712000380_add_push_subscriptions.exs` is removed from the historical
mixed-owner exception. It creates `push_subscriptions` and alters
`notification_intents`; both are owned by `notification_delivery`. Foreign
keys to IdentityAccess tables express referential integrity but do not mutate
those tables and therefore do not create mixed ownership.

## Consequences

- Review records now distinguish the scoped Calls proof point from the actual
  merge unit.
- The empty violation baseline is unchanged; the migration exception list is
  narrowed by one unnecessary entry.
- The historical mixed migrations remain explicit evidence, not precedent for
  new mixed-owner migrations.
- A source revert is not treated as a safe database rollback after production
  migration. Recovery uses the verified backup/restore procedure or a reviewed
  forward repair.
- This retrospective acceptance does not authorize similarly broad future pull
  requests. Future architecture and migration changes remain independently
  reviewable and subject to the strict gate.

## Alternatives rejected

- Describe PR #16 as Calls-only: contradicted by its Git parents and diff.
- Revert the integrated endgame solely because its merge unit was broad: the
  resulting state passes the architecture and CI gates, while a revert would
  introduce greater application and database risk.
- Accept the migrations without operational conditions: several have
  irreversible data effects and require promotion-specific controls.

## Validation

- `git rev-list --count edb0b20..6e60a54` returns 25.
- `git diff --shortstat edb0b20 6e60a54` returns 707 files,
  109,896 insertions, and 2,843 deletions.
- The same diff contains 20 migration files and 1,904 migration-line
  insertions; each is classified in the acceptance record.
- `ecf77da^..ecf77da` contains 70 files, 3,945 insertions, 1,089 deletions,
  and no migration path.
- Pull request #16's backend, web, validation, qualification, manifest,
  security, CodeQL, dependency-review, and pull-request-smoke checks passed.
- Current documentation and strict architecture validation pass after the
  single-owner migration-exception correction.
