# ADR-0045: Harden zero-baseline architecture assurance

- **Status:** Accepted
- **Date:** 2026-07-18
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0001, ADR-0026, ADR-0035, ADR-0042, ADR-0043

## Context

The modularization program reached strict enforcement with an empty finding
baseline, one owner per production module, and one canonical schema per table.
An independent assurance review then found that several classes of future
regression could still evade the analyzer:

- Repo and Ecto.Multi bulk writes could name a foreign table with a string,
  atom, or unresolved expression;
- raw SQL writes were rejected only in read-model modules;
- migration ownership analysis did not cover all Ecto operations, static SQL,
  unresolved targets, or the integrity and staleness of historical exceptions;
- immutable-base manifest comparison protected enforcement state and
  tombstones but not permission-bearing ownership and collaboration changes;
  and
- embedded schemas, `Ecto.Changeset` types, and missing specs on exact
  adapter-facing operations could weaken the Ecto-free contract boundary.

An empty baseline is useful only when the analyzer can fail closed on these
paths. The fix must preserve the single deployment, one database, and existing
business behavior.

## Decision

Keep the current modular monolith and harden its control plane.

### Persistence writes fail closed

The validator attributes Repo and Ecto.Multi bulk mutations through canonical
schemas, literal table strings or atoms, query roots, and supported static
bindings. A write to another context's table is a direct foreign write.
Unknown or dynamic bulk targets are non-baselinable unresolved persistence
writes.

Static non-mutating SQL remains allowed. Raw SQL DML or DDL and unresolved SQL
dispatch are rejected in every production context, not only read models. A
future need for owner-local raw mutation requires an explicit reviewed
extension; it is not inferred as permission.

### Migration exceptions are content-bound

Migration analysis distinguishes mutated tables from referenced tables. It
attributes literal Ecto table, index, constraint, and reference operations,
supported static SQL targets, and fails closed on unresolved mutating targets.
Foreign-key references must name declared tables but do not make the referenced
owner a writer.

Each historical exception records:

- its exact repository path;
- the canonical LF-normalized SHA-256 of the immutable migration;
- the exact permitted finding rules;
- an ADR; and
- a removal condition.

Missing, changed, duplicate, malformed, incomplete, or stale exception entries
fail validation. Exceptions can suppress only their declared historical
mixed-owner or unresolved-target finding; they cannot suppress undeclared
tables.

### Manifest permission growth needs an exact transition

Immutable-base comparison derives deterministic tokens for permission-bearing
semantic changes, including context dependency and public-surface growth,
table ownership or access changes, read-model expansion, new migration
exceptions, runtime collaboration or technical-interface expansion, and
weakened namespace dependency rules.

An approved widening must use one
`enforcement.reviewed_manifest_transitions` entry containing:

- the canonical SHA-256 of the exact base manifest;
- the complete sorted set of approved change tokens;
- an accepted ADR; and
- a removal condition.

The observed token set must equal the approved set. Missing, extra, stale,
duplicate, or reusable declarations fail. Narrowing remains permitted when the
ordinary manifest and source validators confirm it is valid.

### Public adapter contracts remain persistence-neutral

Table-backed and embedded Ecto schemas are internal contracts. Public facade,
contract, callback, and type specifications cannot expose either kind of
schema or `Ecto.Changeset`. Exact technical-interface operations and approved
read-model queries must have matching public specs.

The persistence-returning `Accounts.authenticate/4` and
`Accounts.list_tenant_users/1` implementations are private. Callers use the
existing view, access-context, and projection APIs. Cross-owner lifecycle
errors remain persistence-neutral:
`Accounts.apply_user_lifecycle_change/4` converts owner-internal changeset
failures to the stable `CommsCore.ValidationError` DTO through its declared
technical-interface caller instead of exposing `Ecto.Changeset`.

This tranche does not add cosmetic specs to every legacy public function.
Complete operation-level API freezing requires explicit `public_operations`
declarations and focused facade/internal separation; generic
`term() -> term()` specifications would not create a meaningful boundary.

## Consequences

- The empty baseline now covers more write, migration, manifest, and contract
  regression paths.
- Historical migrations remain untouched; their narrowly scoped evidence is
  stronger and self-invalidates if a file changes.
- Legitimate manifest permission growth requires a short-lived exact
  ADR-backed transition.
- Existing adapter behavior is preserved through Ecto-free projections.
- The remaining operation-level API inventory is explicit future work rather
  than an unsubstantiated claim of full facade freezing.

## Alternatives rejected

- Keep the empty baseline without analyzer changes: zero would remain a
  reporting result rather than a reliable prevention guarantee.
- Ban every Ecto type name: scalar `Ecto.UUID` types and explicitly governed
  transaction-contributing `Ecto.Multi` contracts are not persistence schema
  leakage.
- Grandfather dynamic writes or stale migration exceptions: either would turn
  strict enforcement into convention.
- Add generic specs to all facade functions: this would create volume without
  declaring or stabilizing the actual public operation set.
- Split contexts into services or umbrella applications: no independent
  deployment or scaling need exists.

## Validation

- The full architecture-validator regression suite passes.
- Live strict validation reports zero findings with an empty baseline.
- Deterministic architecture-report verification passes.
- Mutation regressions cover literal and dynamic Repo/Ecto.Multi targets,
  raw-SQL write paths, and owner-local negative controls.
- Migration regressions cover Ecto and SQL targets, references, dynamic
  targets, exception shape, hashes, rules, staleness, and undeclared tables.
- Immutable-base tests cover protected widening, valid narrowing, and exact
  ADR-backed transition matching.
- Public-contract tests reject embedded schemas and changesets and require
  specs for exact adapter-visible operations.
