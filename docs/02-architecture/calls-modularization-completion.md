# Calls modularization completion record

**Date:** 2026-07-17
**Decision:** ADR-0043
**Scope:** The final Calls-only boundary tranche authorized by ADR-0042.

## Result

The Calls tranche removes the complete 29-finding residual architecture set:

| Rule | Before | After |
|---|---:|---:|
| `adapter_schema_import` | 1 | 0 |
| `business_context_cycle` | 1 | 0 |
| `foreign_schema_import` | 19 | 0 |
| `undeclared_context_edge` | 8 | 0 |
| **Total** | **29** | **0** |

The source analyzer returns no boundary violations. The empty baseline and
deterministic report were regenerated only after implementation, validator,
and behavioral verification, so neither artifact can hide an implementation
or validator defect.

## Implemented boundary

- `audio_calls` and `audio_call_participants` remain Calls-owned tables with
  one canonical schema each.
- Foreign Ecto associations were replaced by scalar identifiers. The remaining
  participant-to-call association is entirely inside Calls ownership.
- `CommsCore.AudioCalls` remains the single Calls facade.
- Released adapters consume only `CallView`, `CredentialRequest`,
  `EvictionClaim`, `EvictionProgress`, and `ProviderCall`.
- `AudioCalls.AuthorizationPolicy` owns call authorization and consumes
  Ecto-free owner projections from IdentityAccess, TenantAdministration, and
  Conversations.
- IdentityAccess, TenantAdministration, and Conversations contribute
  transaction-scoped revocation through exact consumer-owned lifecycle ports.
- `CommsCore.Authorization` and the `:authorization_adapter` binding are
  retired; their namespace and binding tombstones are immutable.

## Compatibility

No database migration, table rewrite, umbrella-app split, deployment-unit
change, or microservice extraction is part of this tranche. REST, WebSocket,
LiveKit, transactional-outbox, call-expiry, and participant-eviction semantics
remain the existing externally observable contracts. The event catalogue
continues to publish canonical `call.started.v1` and `call.ended.v1` together
with the existing `audio_call.started.v1` and `audio_call.ended.v1`
compatibility aliases; no new public event contract is introduced.

## Control-plane finalization

The manifest records an exact 29-to-zero transition from baseline SHA-256
`90a52be007eecd64627b35212ec3da314e742f232373a6e954523116f4fa1da6`.
It declares the three lifecycle collaborations, Calls public contracts,
owner-internal namespaces, forbidden reverse dependencies, retired
authorization namespace, and retired runtime binding.

Strict mode is stronger than the former deferral mode:

- analyzer violations must be empty;
- the checked-in baseline must be empty;
- temporary violations and baseline-adoption metadata must be absent;
- the deferral policy must be absent;
- immutable-base comparison rejects any later downgrade or tombstone removal.

The combined diagnostic graph may still show an SCC created solely by an exact
consumer-owned dependency inversion. Compiled and runtime graphs remain
individually acyclic; the union is diagnostic and does not authorize an
undeclared edge.

## Verification evidence

| Gate | Result |
|---|---|
| Python validator compilation and Ruff | Passed |
| Architecture-validator regressions | 165 passed |
| Strict architecture validation | 0 findings; 37 compiled, 6 runtime, and 43 combined edges |
| Empty baseline and generated-report parity | Passed |
| Immutable-base comparison | Exact 29-to-zero transition accepted; downgrade and tombstone removal rejected |
| Elixir formatter | Passed |
| Test and production warnings-as-errors compilation | Passed |
| Full umbrella tests on a newly created database | 423 passed |
| Configured Calls lifecycle integration and rollback tests | 10 passed |
| Compile-connected and all-file `comms_core` xref | No cycles found |
| Contract validation | 2 JSON Schemas, OpenAPI 3.1, AsyncAPI 3.0, and documentation mirrors passed |
| Documentation validation | 203 Markdown files passed |

The combined graph has one diagnostic SCC created by declared consumer-owned
dependency inversions; its compiled and runtime graphs are individually
acyclic. The baseline and generated report remain evidence outputs, not inputs
to the implementation.
