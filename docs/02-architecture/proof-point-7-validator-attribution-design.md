# Proof Point 7: table-owner-aware write attribution

Historical note: this records the validator at Proof Point 7 completion.
Proof Point 9 supersedes its namespace-only read/edge attribution by using
canonical schema ownership, expanding root grouped aliases, and fingerprinting
exact SCC edges. Counts below are not comparable to the hardened current
baseline.

## Context

At the start of Proof Point 7, the boundary validator reported
`direct_foreign_write` when both of
these conditions are true anywhere in the same source file:

1. the file references a schema assigned to another context by namespace; and
2. the file contains any `Repo.insert`, `Repo.update`, or `Repo.delete` family
   call.

This file-level co-occurrence rule is deliberately conservative, but it
misclassifies modules that write their own tables while reading foreign tables.
It also misclassifies `CommsCore.Accounts.Tenant`: the schema lives under the
historical `Accounts` namespace while the manifest declares the `tenants` table
as owned by `tenant_administration`.

At the start of Proof Point 7 the baseline contains 20
`direct_foreign_write` candidates. Manual inspection classifies five non-audio
entries as genuine, two as deferred audio work, and thirteen as read-only or
ownership-resolution false positives.

## Canonical owner map

The validator builds the schema owner map from
`docs/02-architecture/context-boundaries.yaml`:

```text
tables.<table>.canonical_schema -> tables.<table>.owner
```

At Proof Point 7 completion, this map was authoritative only when attributing a
persistence write target. Proof Point 9 intentionally made it authoritative for
schema reads and dependency edges as well; namespace ownership remains the
fallback for non-schema modules.

This distinction ensures that a write to `CommsCore.Accounts.Tenant` is
attributed to `tenant_administration`, even though the historical schema
namespace is `Accounts`. A write from `CommsCore.Accounts` is therefore a
genuine `identity_access -> tenant_administration` persistence violation.
Compiled imports of that schema continue to be classified by their actual
module namespace and remain visible through the separate dependency rules.

## Write attribution rules

A `direct_foreign_write` is reported only when production code persists a
canonical schema owned by another context. Supported write shapes are:

- schema changeset expressions, including named changesets such as
  `service_changeset`, `edit_changeset`, and `delete_changeset`, when the
  resulting changeset is passed to a recognized Repo, Multi, pipeline, or local
  write wrapper;
- direct `Repo.insert`, `Repo.update`, or `Repo.delete` calls with a typed
  schema struct;
- `Repo.insert_all` with a canonical schema;
- `Repo.update_all` or `Repo.delete_all` whose direct `from` target is a
  canonical schema;
- bulk writes through a local query variable whose source schema can be
  resolved; and
- typed local variables passed to `Repo.insert`, `Repo.update`, or
  `Repo.delete`.

`Ecto.Multi.insert`, `Ecto.Multi.update`, and `Ecto.Multi.delete` are covered
when their changeset or typed struct identifies the persistence schema.

The following are not write violations:

- read-only `Repo.get`, `Repo.one`, `Repo.all`, `Repo.exists?`, aggregates, and
  joins;
- a module writing its own canonical schema while also reading a foreign
  schema;
- writes where the canonical table owner equals the source context, even when
  the schema resides in a historical namespace; and
- calls to an allowed owner facade or DTO/projection API that do not construct
  or persist the owner's schema.

## Dependency edges remain separate

Write attribution does not suppress dependency analysis. A read-only import or
query can still produce `undeclared_context_edge`, participate in the business
dependency graph, or violate an owner-only schema rule. Read access must still
be routed through an allowed facade/projection or documented as a narrowly
enforced read-model exception.

## Proof Point 6 regressions

The validator test suite keeps repository-level checks that Messaging:

- calls `Conversations.reserve_message_slot/2`,
  `validate_active_members/3`, and `active_conversation_ids/1`;
- does not reference `CommsCore.Conversations.Conversation`,
  `CommsCore.Conversations.Membership`, or `CommsCore.Accounts.User`; and
- declares `CommsCore.Conversations.MessageWriteSlot` as a public contract.

Fixture tests additionally prove that a new Messaging-style foreign changeset
or bulk write is reported even when the module also performs legitimate
same-owner writes. The attribution change removes false positives; it does not
create a permanent exception for any module or context.

## Re-baselining rule

The baseline is regenerated only after:

1. positive and negative attribution tests pass;
2. the repository report contains every manually confirmed genuine write;
3. read-only candidates disappear without suppressing their dependency edges;
4. the architecture validator rejects a newly introduced genuine foreign
   write; and
5. the relevant Elixir tests and warnings-as-errors compilation remain green.

## Verified Part A result

Part A was re-baselined only after 37 validator tests and warnings-as-errors
compilation passed.

| Measure | Before | After Part A |
|---|---:|---:|
| Total tracked boundary findings | 29 | 14 |
| `direct_foreign_write` candidates/findings | 20 | 5 |
| `undeclared_context_edge` | 7 | 7 |
| `adapter_schema_import` | 1 | 1 |
| `business_context_cycle` | 1 | 1 |

The five genuine write groups were two in `CommsCore.Accounts` (Tenant
Administration and Conversations ownership) and three in
`CommsCore.Governance` (IdentityAccess, ConversationContent, and Conversations
ownership). Part B removes the two Accounts groups; it does not change the
Governance findings or claim that the business-context cycle is resolved.
