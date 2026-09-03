# ADR-0075: Freeze public facade operations by bounded context

- **Status:** Accepted
- **Date:** 2026-09-03
- **Owners:** Architecture, Core, Security
- **Reviewers:** Architecture, Security, Release and Quality
- **Related requirements:** ADR-0026, ADR-0035, ADR-0045, ADR-0062

## Context

ADR-0045 made exact technical-interface and read-model operations typed and
persistence-neutral, but deliberately left the wider legacy facade surface as
future work. A facade could therefore gain a new exported operation without an
explicit API decision. Adapter calls through that surface also had no complete
operation-level inventory. Separately, raw-SQL mutation analysis covered
`Ecto.Adapters.SQL.query/3` and `query!/3`, but not the equivalent direct
Postgrex APIs.

The correction must preserve the modular monolith, existing deployment units,
transaction ownership, and the zero-finding architecture baseline.

## Decision

1. `docs/02-architecture/public-facade-api.yaml` is the complete checked-in
   facade inventory, grouped by bounded context and module. Every exported
   facade arity is classified exactly once as adapter-public, cross-context
   collaboration, or owner-internal.
2. The boundary manifest binds that snapshot by path and SHA-256. Future hash
   changes are immutable-base manifest changes and require an exact accepted
   ADR-backed transition.
3. Every adapter-public operation has an explicit, non-generic typespec. Its
   contract may name only persistence-neutral DTOs, scalars, bounded maps, and
   explicit errors; all `Ecto.*`, `term()`, and `any()` types are rejected.
4. Public DTO structs have named `t()` types. Existing adapter contract tests
   continue to assert concrete view/result shapes, while the validator proves
   those named public contracts are not canonical or embedded Ecto schemas and
   that adapters do not reference schemas or `Ecto.Changeset`.
5. Cross-context collaboration operations remain separately visible because
   some deliberately contribute to caller-owned transactions. They are not
   silently reclassified as browser or worker APIs. Owner-internal operations
   cannot be called by released adapters or foreign bounded contexts.
6. Raw-SQL write analysis treats direct, aliased, imported, statically bound,
   captured, delegated, and dynamic `Postgrex.query/3` and `query!/3` calls with
   the same fail-closed rules as `Ecto.Adapters.SQL`.
7. Static call arity follows Elixir semantics: a trailing keyword sequence is
   one list argument. This prevents false operation names such as inflated
   arities for calls with several keyword pairs.

## Consequences

- Facade growth is now an explicit review event rather than an incidental
  exported function.
- Accidental legacy exports stay classified as owner-internal without receiving
  cosmetic catch-all specs.
- Adapter-visible contracts cannot use a canonical schema, changeset, or broad
  `term()` escape hatch to satisfy the gate.
- The inventory generator is a deterministic maintenance tool; its output
  remains subject to the manifest hash and normal architecture review.
- No runtime behavior, database schema, deployment topology, or service
  boundary changes.

## Alternatives considered

| Alternative | Advantages | Disadvantages | Decision |
|---|---|---|---|
| Add `term() -> term()` specs to every export | Small mechanical diff | Does not declare intent or constrain persistence leakage | Rejected |
| Treat every legacy export as adapter-public | Simplest inventory | Freezes implementation helpers and transaction collaborations as product API | Rejected |
| Privatize every non-adapter export immediately | Smallest theoretical surface | Breaks established cross-context collaboration and creates a broad refactor | Rejected |
| Add a shared facade policy kernel | Centralized checks | Reintroduces the cross-context coupling already retired by ADR-0043 | Rejected |

## Validation

- Architecture tests cover default-generated arities, exact classification,
  generic-spec rejection, owner-internal access rejection, and hash binding.
- Raw-SQL tests cover direct, aliased, statically bound, captured, and dynamic
  Postgrex mutation paths.
- Full architecture validation and immutable-base comparison must remain at
  zero findings.
- Elixir formatting and warnings-as-errors compilation must pass.

## Revisit triggers

- A facade operation must become adapter-public or be retired.
- A collaboration no longer needs caller-owned transaction semantics.
- Elixir syntax accepted by the application can no longer be attributed by the
  static parser without ambiguity.
