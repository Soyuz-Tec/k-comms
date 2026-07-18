# ADR-0035: Complete the modular-monolith boundary control plane

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0001, ADR-0026, ADR-0032, ADR-0034
- **Supersedes:** The baseline and graph-enforcement mechanics in ADR-0026

## Context

ADR-0026 established one table owner, one canonical schema, declared context
facades, and a no-growth architecture baseline. Subsequent proof points reduced
the tracked baseline to 95 findings and introduced transaction-scoped
dependency-inversion ports.

The control plane is not yet complete. Namespace inference does not attribute
13 production `CommsCore` modules. One of those modules,
`CommsCore.Authorization.Database`, reads persistence owned by several business
contexts and therefore hides material coupling from the context graph.
Runtime collaborations and temporary violations are documented but are not yet
generic, exact, machine-checked policy. A compiled-only graph also understates
the runtime control flow introduced by dependency inversion.

## Decision

Keep the current single deployment, one `CommsCore.Repo`, and one database.
Extend `context-boundaries.yaml` rather than splitting the umbrella into
services or applications.

### Exact module ownership

Canonical-schema ownership remains authoritative for Ecto schemas. Every other
production module must resolve to exactly one owner by an exact
`owned_modules` declaration or an unambiguous declared namespace.

The previously unattributed modules have these exact owners:

| Owner | Modules |
|---|---|
| IdentityAccess | `CommsCore.Security.Password` |
| NotificationDelivery | `CommsCore.Security.PushSubscriptionBox` |
| WebhookManagement | `CommsCore.Security.SecretBox` |
| PlatformPersistence | `CommsCore.DatabaseTLS`, `CommsCore.Repo`, `CommsCore.Schema` |
| PlatformRuntime | `CommsCore.Application`, `CommsCore.Release`, `CommsCore.RuntimePorts`, `CommsCore.ValidationError` |
| AuthorizationKernel, temporary | `CommsCore.Authorization`, `CommsCore.Authorization.Database`, `CommsCore.Authorization.DenyAll` |

PlatformPersistence and PlatformRuntime remain fully subject to attribution,
schema-access, direct-write, public-contract, and adapter checks. They are
graph-neutral because ubiquitous Repo, schema-macro, runtime-port, and
composition-root references are technical wiring rather than business
dependencies.

AuthorizationKernel is deliberately graph-visible and has no broad business
dependency allowance. Its current foreign-schema imports and incoming and
outgoing business edges must therefore be reported. It is not a permanent
shared kernel. It is removed after non-media decisions move to the contexts
that own the protected state, any retained Calls clauses move behind the Calls
boundary using Ecto-free contracts, and `Authorization.Database` can be
deleted.

Missing and multiply attributed production modules are integrity failures and
cannot be baselined.

### Three dependency graphs

The validator derives and reports three graphs:

1. **Compiled:** an edge from the owner of a production source module to the
   owner of a referenced module. Graph-excluded technical owners do not
   contribute edges, but remain enforcement subjects.
2. **Runtime:** an edge from a declared collaboration consumer to its provider.
3. **Combined:** the union of compiled and runtime edges.

Compiled and runtime cycles are architectural debt and require one exact
ADR-backed temporary-violation declaration and removal condition when
retained. Combined SCCs are always reported, but are not double-counted as a
second violation when they arise from an exact, validated dependency-inversion
collaboration: the provider's compile-time reference to the consumer-owned
port and the consumer's runtime delegation to the provider describe one
intentional one-way collaboration.

### Runtime collaborations

Every synchronous runtime collaboration declares exactly one consumer,
provider, consumer-owned port, provider implementation, result contract,
caller set, operation set, composition-root binding, and transaction policy.
Source and configuration must match the declaration exactly.

The manifest records both existing collaborations:

- IdentityAccess to Conversations for initial-conversation bootstrap; and
- IdentityAccess to NotificationDelivery for recovery notification and
  access-revocation effects.

Neither declaration grants a general service-locator capability. Adding a
caller, operation, binding, or implementation requires architecture review.

### Strict explicit-deferral mode

Enforcement remains in `baseline` mode while the newly truthful graph is
generated and reviewed. The target mode is
`strict_with_explicit_deferrals`.

Before that mode can be activated:

- every production module has exactly one owner;
- every retained baseline fingerprint maps to exactly one temporary-violation
  declaration;
- every declaration records its exact fingerprint, rule, path, detail, ADR,
  and removal condition;
- stale, duplicate, and unmapped declarations fail;
- a group is accepted only after expansion to an exact fingerprint list; and
- CI compares against the pull request base, requires no growth, and verifies
  deterministic baseline and report output.

The first truthful-analyzer adoption is content-bound to the exact SHA-256 of
the preceding 95-finding baseline and an exact reviewed, sorted set of newly
exposed or mechanically changed fingerprints. It cannot authorize another base
file or any fingerprint outside that set, and is removed after the truthful
baseline reaches the protected branch.

Later reviewed reductions use a separate, short-lived baseline transition.
Each transition is bound to the exact SHA-256 of one preceding baseline and
declares the complete, sorted sets of both added and removed fingerprints.
Comparison succeeds only when both observed sets equal the declaration; an
undeclared addition, undeclared removal, stale declaration, duplicate base
hash, or reuse against another base fails. The transition is removed after its
resulting baseline reaches the protected branch. This mechanism records
detail-sensitive replacement fingerprints without converting debt reduction
into an open growth allowance.

Direct foreign writes, duplicate table mappings, public Ecto contracts,
unclassified or ambiguous modules, undeclared runtime bindings, and new
adapter persistence or implementation leaks are never baselinable.
The already tracked Calls presenter leak may remain only as its exact
grandfathered fingerprint until its declared Calls-owned view removal
condition is met.

## Consequences

- The finding count and principal strongly connected component may initially
  grow because previously hidden authorization debt becomes visible.
- Platform wiring no longer disappears from ownership checks, while the
  business graph stays readable.
- Dependency inversion is represented honestly as opposite compiled and
  runtime directions.
- Combined SCCs are reported as topology rather than double-counted when they
  are caused solely by exact validated dependency-inversion collaborations;
  compiled and runtime cycles remain independently enforceable violations.
- The existing baseline remains migration debt, not permission to add another
  violation.
- Strict mode cannot be enabled by merely refreshing a baseline; every retained
  exception requires an exact, reviewable decision.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Continue namespace inference and skip unmatched modules | It hides the largest cross-context policy dependency and makes the graph incomplete. |
| Declare Authorization as a permanent shared kernel | It legitimizes foreign persistence reach-through and centralizes policy away from state owners. |
| Include Repo and RuntimePorts as business graph nodes | Ubiquitous technical wiring obscures the business dependency graph without improving ownership enforcement. |
| Treat a reversed compile edge as no dependency | It conceals synchronous runtime control flow and can hide combined cycles. |
| Enable strict mode before regenerating the graph | It would approve stale fingerprints rather than reviewed residual debt. |

## Validation

Completion requires:

- all production `CommsCore` modules resolve to one owner;
- the six exact ownership groups above account for all 13 previously skipped
  modules;
- AuthorizationKernel participates in foreign-schema, edge, and cycle
  analysis;
- both runtime collaborations match their source, callbacks, callers,
  configuration bindings, and transaction requirements;
- compiled, runtime, and combined graph output is deterministic;
- deleting or expanding a runtime declaration fails validation;
- strict mode rejects missing, stale, duplicate, or mismatched deferrals; and
- the manifest parses, architecture validator tests pass, and baseline mode
  continues rejecting every new violation while the honest baseline is
  prepared.
