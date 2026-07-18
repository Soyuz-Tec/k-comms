# Proof Point 9: one-way Governance dependency direction

Status: complete and verified on 2026-07-17.

This is the repository-effective ninth proof point. It implements the
request-numbered Proof Point 7 without renaming or overwriting the existing
Proof Point 7 and 8 records.

The graph and baseline counts below are the verified Proof Point 9 snapshot.
Proof Point 10 subsequently removes IdentityAccess to ConversationContent,
reduces the principal SCC to five contexts, and records the current graph in
`proof-point-10-service-message-owner-direction.md`.

## Outcome

The implemented dependency direction is:

```text
TrustGovernance -> IdentityAccess
TrustGovernance -> TenantAdministration
```

The reverse `IdentityAccess -> TrustGovernance` edge is removed. Accounts no
longer imports or queries `CommsCore.Governance.DeletionRequest`. Governance
owns the approved/in-progress deletion query and supplies only user identifiers
to a transaction-required IdentityAccess lifecycle command.

TenantAdministration publishes
`CommsCore.Administration.RetentionDefaults`. Governance calls only
`CommsCore.Administration.retention_defaults/1` and no longer imports or queries
`TenantSettings`.

`CommsCore.Operations` is now a genuine read-only projection module. Retry
commands were removed from it; the released operations controller dispatches
each command to the owning Attachments, NotificationDelivery, or
WebhookManagement facade.

## Control-plane enforcement

The architecture validator now:

- expands root and nested grouped aliases, resolves chained aliases, and
  rejects files whose multiple `defmodule` declarations cannot be attributed
  to one owner;
- attributes Ecto schemas to the manifest's canonical table owner;
- treats every canonical CommsCore schema as owner-internal by default;
- permits read exceptions only for exact public contracts, arity-qualified
  public query callables, and source tables;
- rejects protected-call imports, captures, dynamic dispatch, wrong arities,
  owner commands, Repo/Ecto.Multi/Oban writes, and unresolved or mutating raw
  SQL from read-only exception modules;
- keeps read-model exceptions out of reverse dependencies and cycles;
- fingerprints a business SCC by both its members and every internal edge;
- rejects stale/resolved baseline fingerprints;
- refuses to write a baseline containing non-baselinable read-model control
  violations; and
- allows the exclusion-bearing Accounts lifecycle functions to be called only
  from `CommsCore.Governance` in production code.

The Governance exception grants exactly
`CommsCore.Administration.retention_defaults/1` and
`CommsCore.Administration.RetentionDefaults`, with no source-table grant.
The Operations exception grants exactly five source-table reads and no public
query or command grant.

## Transaction behavior

The governed lifecycle path is one database transaction:

1. Accounts validates the user ID, tenant ID, authorization, version, reason,
   role, and status before Governance acquires a lock.
2. Governance takes its tenant-scoped PostgreSQL transaction advisory lock.
3. Governance reads approved and in-progress user-deletion exclusions.
4. Accounts takes the tenant admission lock and locks tenant users in
   deterministic ID order.
5. Accounts evaluates the last-owner invariant and applies the identity
   mutation.
6. Revocation and audit work either commit with the user change or roll back
   with it.

Deletion approval takes the same Governance lock before locking its request and
tenant users. Independent-connection tests prove both orderings: approval blocks
an unsafe owner demotion, and owner demotion blocks an unsafe approval.

No Ecto schema crosses the owner-lifecycle or retention facade introduced by
this proof point. Governance still has pre-existing direct IdentityAccess,
Conversations, and ConversationContent schema reads in other workflows; those
remain explicit temporary encapsulation debt rather than public contracts.

## Architecture delta

The comparable business-graph slice uses the same grouped-alias and
canonical-owner attribution on both sides:

| Measure | Before | After |
|---|---:|---:|
| Undeclared edge fingerprints | 16 | 14 |
| Business SCC size | 7 contexts | 6 contexts |

This proof point removed two real undeclared directions. The final baseline
contains 105 findings because the validator now also enforces schema
encapsulation by default and exposes 89 pre-existing schema-containment
violations: 83 foreign-schema imports and 6 owner-internal schema accesses.
The complete current breakdown is 83 foreign-schema imports, 6 internal-schema
accesses, 14 undeclared edges, 1 six-context SCC, and 1 deferred audio adapter
leak. The higher total is corrected visibility, not coupling introduced by this
refactor.

The remaining business SCC contains Calls, ConversationContent, Conversations,
IdentityAccess, NotificationDelivery, and TenantAdministration. Its fingerprint
includes the exact internal edge set, so adding or changing an edge cannot hide
inside the existing SCC.

## Residual inventory

There are no tracked direct foreign-write violations. The 14 temporary
undeclared edge fingerprints are:

| Location | Classification | Residual direction |
|---|---|---|
| `accounts.ex` | Temporary allowed debt | IdentityAccess to Calls, Conversations, and NotificationDelivery |
| `administration.ex` | Temporary allowed debt | TenantAdministration to Calls |
| `admission_quotas.ex` | Reverse dependency/direct schema read | TenantAdministration to Conversations |
| `conversations.ex` | Temporary allowed debt | Conversations to Calls |
| `notifications/attempt.ex` | Foreign schema association | NotificationDelivery to TenantAdministration |
| `notifications/intent.ex` | Foreign schema association | NotificationDelivery to TenantAdministration |
| `notifications/preference.ex` | Foreign schema association | NotificationDelivery to TenantAdministration |
| `notifications/push_subscription.ex` | Foreign schema association | NotificationDelivery to TenantAdministration |
| `password_recovery.ex` | Cross-context coordination | IdentityAccess to Calls and NotificationDelivery |
| `service_accounts.ex` | Reverse dependency/direct schema read | IdentityAccess to ConversationContent and Conversations |

The 89 schema-containment findings are enumerated individually, with exact
paths and fingerprints, in `context-boundary-violations.md`. They are now
baseline debt rather than parser blind spots, and CI rejects any new, changed,
or silently resolved fingerprint.

The audio presenter schema leak remains the one explicitly deferred adapter
violation. No audio/video implementation or migration was changed.

`CommsCore.Authorization.Database` remains a central, currently unattributed
schema-reading module. It is not counted as a business edge until authorization
ownership is explicitly modeled; resolving that attribution gap is a follow-up,
not an excuse to broaden this proof point.

## Verification

- `mix format --check-formatted`: passed.
- `MIX_ENV=test mix compile --warnings-as-errors`: passed.
- Full umbrella ExUnit suite: 298 passed.
- Independent PostgreSQL connection race suite: 3 tests passed across 6
  consecutive runs (18 test executions).
- Architecture validator tests: 72 passed.
- Architecture validator: passed with exactly 105 tracked findings and zero
  non-baselinable violations.
- Python compilation and `git diff --check`: passed.
- Mix xref: 229 files, 85 compile edges, 142 export edges, 532 runtime edges,
  and 10 file-level cycles.

No database migration, microservice extraction, event replication, database
rewrite, or audio/video refactor is part of this proof point.
