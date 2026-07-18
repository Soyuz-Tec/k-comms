# ADR-0026: Enforce business-context boundaries inside comms_core

- **Status:** Accepted
- **Date:** 2026-07-16
- **Owners:** Architecture and engineering
- **Related requirements:** ADR-0001 modular monolith

## Context

The umbrella application graph is clean, but business contexts inside
`comms_core` share schemas, tables, migrations, and bidirectional dependencies.
The existing validator protects technical application boundaries only. K-Comms
is still before meaningful live-user validation, so establishing enforceable
ownership now is cheaper than preserving accidental contracts later.

## Decision

Keep one release, one `CommsCore.Repo`, and one PostgreSQL database. Define the
authoritative business and technical ownership model in
`docs/02-architecture/context-boundaries.yaml`.

Every table has exactly one owner. Application tables have one canonical Ecto
schema; third-party/framework tables declare their canonical external schema or
accessor. Ecto schemas are internal implementation details. Cross-context
access must use a declared facade, command, query projection, or versioned
event. Dependencies must match the manifest and be one-way. Operations is a
documented read-only projection exception; transactional outbox storage has the
narrow technical owner `PlatformEventing`.

`scripts/validate_architecture.py` compares detected violations with a tracked
baseline. Relative to that checked-in baseline, new, changed, and resolved
fingerprints fail CI. The baseline is temporary debt, not an allowlist for new
code, and baseline edits require architecture review.

The first proof points after enforcement are eliminating the duplicate `users`
schema and making `AuditEvent` internal behind `Audit.record/1` or
`Audit.append/2`.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Separate every context into an umbrella application | Premature build fragmentation and unnecessary movement before boundaries are proven. |
| Rely on Phoenix context conventions | Existing schema reach-through and cycles demonstrate that convention is insufficient. |
| Introduce microservices or separate databases | Adds distributed failure modes without validated scaling or ownership need. |
| Move code before defining ownership | Creates churn without a testable target architecture. |

## Consequences

- Architectural ownership becomes reviewable and CI-enforced.
- Existing violations remain visible while incremental refactoring proceeds.
- New contexts, table owners, dependencies, projections, and exceptions require
  a manifest change and architecture review.
- Static analysis is intentionally conservative; reviewed false positives must
  be corrected in the analyzer or recorded as narrow, expiring exceptions.

## Validation

- The manifest parses and assigns every discovered table exactly one owner.
- Architecture tests cover duplicate schemas, adapter schema imports,
  undeclared edges, mixed-owner migrations, public Ecto contracts, and cycles.
- CI rejects a violation not present in the tracked baseline.
- The baseline decreases as proof-point and later context refactors land.

## Revisit triggers

- A context cannot preserve an invariant through its declared API.
- Live workflow evidence demonstrates that a proposed boundary creates material
  development or performance friction.
- A regulatory, scaling, or team-ownership requirement justifies stronger
  physical isolation.
