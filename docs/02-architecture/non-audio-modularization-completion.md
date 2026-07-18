# Non-audio modularization completion record

**Date:** 2026-07-17
**Decision:** ADR-0042
**Scope:** All modular-monolith restructuring except the separately authorized
Calls/audio boundary.

## Result

At the ADR-0042 checkpoint, the non-audio endgame was complete and the
architecture analyzer reported 29 findings, all of which were exact Calls/audio
deferrals:

| Rule | Retained | Non-audio retained |
|---|---:|---:|
| `adapter_schema_import` | 1 | 0 |
| `business_context_cycle` | 1 | 0 |
| `foreign_schema_import` | 19 | 0 |
| `undeclared_context_edge` | 8 | 0 |
| **Total** | **29** | **0** |

At that checkpoint, the combined diagnostic graph could report SCCs created by
declared dependency inversions: consumer-to-provider runtime control flow is
paired with provider-to-consumer compile-time implementation of a consumer-owned
port. Those exact validated inversions are accepted topology, not retained
violation fingerprints. The only retained violation SCC was the Calls-driven
compiled SCC.

The completed non-audio scope had zero `internal_schema_access`,
`adapter_internal_module_import`, duplicate table mappings, public Ecto
contracts, direct foreign writes, unclassified modules, invalid runtime
collaborations, and invalid technical interfaces.

## Implemented endgame controls

- Owner-internal Admission policy reading, centralized tenant authorization,
  and transaction-required Outbox persistence.
- Scalar Webhook/outbox and low-value inverse association boundaries.
- Exact released technical interfaces for validation rendering, recovery
  release work, Outbox publication, and notification availability.
- Retry-safe, idempotent notification availability signaling and observable
  outbox attempt recording without exposing persistence structs.
- Adapter-internal module enforcement across production web, worker, and
  integration sources.
- Exact fingerprint-to-deferral mapping with residual-cycle checks so Calls
  cannot mask independent non-audio debt.
- Strict deferral mode, deterministic report parity, paired immutable-base
  baseline/manifest enforcement, protected-rule pre-adoption rejection, and
  zero-cycle `comms_core` xref gates.

## ADR-0042 verification evidence

The delivery gate completed against a newly created and migrated test database:

| Gate | Result |
|---|---|
| Elixir formatter | Passed |
| Warnings-as-errors compilation | Passed |
| Full umbrella tests | 404 passed |
| Architecture-validator tests | 154 passed |
| Architecture validation | 29 tracked findings; 44 compiled, 3 runtime, and 47 combined edges |
| Contract validation | 2 JSON Schemas, OpenAPI 3.1, AsyncAPI 3.0, and documentation mirrors passed |
| Documentation validation | 201 Markdown files passed |
| Generated-report parity | Passed |
| Paired immutable-base comparison | Passed against canonical baseline SHA-256 `9190df9731fc781d1154e9e9d6ec1b27f7557a60cac6afc582b8d7d6f0ceb4d6` and the base manifest; planned baseline-to-strict activation was accepted and post-activation downgrade is locked |
| Compile-connected xref | No cycles found |
| All-file xref | No cycles found |

The evidence checked in for the ADR-0042 checkpoint was:

- `context-boundary-baseline.yaml`: 29 exact findings.
- `context-boundary-violations.md`: deterministic report and compiled,
  runtime, and combined graphs.
- `context-boundaries.yaml`: active `strict_with_explicit_deferrals` mode and
  one-to-one Calls deferral declarations.

## Work remaining at the ADR-0042 checkpoint

The next structural tranche was Calls only. It had to introduce Calls-owned
Ecto-free views and policy inputs, replace foreign schema associations with
scalar IDs, move media authorization behind the Calls facade, remove the
temporary authorization kernel, and delete every one of the 29 deferrals. It
was not to be combined with unrelated domain restructuring.

## Forward completion note

ADR-0043 subsequently completed that separately authorized Calls tranche. The
historical 29-finding evidence above remains the ADR-0042 checkpoint; it is not
the current architecture state. See
`calls-modularization-completion.md` for the 29-to-zero transition, strict
zero-baseline gate, consumer-owned lifecycle ports, and authorization-kernel
retirement.
