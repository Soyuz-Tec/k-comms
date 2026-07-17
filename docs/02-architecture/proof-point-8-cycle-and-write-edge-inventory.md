# Proof Point 8: remaining cycle and write-edge inventory

Status: implemented  
Starting baseline: 12 tracked findings after Proof Point 7

Historical note: the 12-to-9 counts in this Proof Point 8 record used the
pre-hardening parser. Proof Point 9 now expands root grouped aliases and uses
canonical schema ownership for reads and edges, exposing five previously hidden
grouped-alias edges and four previously misattributed schema-owner edges.

## Scope decision

The attached request still labels this work Proof Point 6, but the repository
has completed Proof Points 6 and 7. This document uses the repository-effective
next number and applies the requested outcome to the current baseline.

This slice removes the three remaining direct foreign-write groups from
`CommsCore.Governance`. Each write is moved behind a transaction-required owner
API while the existing Governance transaction remains the coordinator.

The slice also removes the direct ConversationContent → TrustGovernance
dependency used by message deletion. Governance now owns the legal-hold-aware
use case and passes a persistence-neutral deletion candidate to the
ConversationContent owner operation. This removes the concrete
`Governance`/`Messaging` xref cycle without a broad rewrite of the seven-context
strongly connected component.

## Starting baseline

| Rule | Count | Classification |
|---|---:|---|
| `direct_foreign_write` | 3 | Genuine ownership defects in Governance |
| `undeclared_context_edge` | 7 | Six reverse dependencies and one read-projection candidate |
| `business_context_cycle` | 1 | Seven business contexts in one SCC |
| `adapter_schema_import` | 1 | Deferred audio adapter debt |
| Total | 12 | |

The SCC diagnostic is a sorted component member list, not a literal directed
path. It contains Calls, ConversationContent, Conversations, IdentityAccess,
NotificationDelivery, TenantAdministration, and TrustGovernance.

## Direct-write inventory

All nine writes execute from `Governance.complete_deletion_request/4` inside
the same database transaction as the Governance request completion and audit.

| Priority | Location | Foreign schema/table | Operation | Owner | Replacement |
|---:|---|---|---|---|---|
| 1 | `governance.ex`, conversation target | `Conversation` / `conversations` | Archive with `update_all` | Conversations | `Conversations.archive_for_erasure/3` |
| 1 | `governance.ex`, user target | `Membership` / `conversation_memberships` | Set `left_at` with `update_all` | Conversations | `Conversations.remove_user_memberships_for_erasure/3` |
| 2 | `governance.ex`, message cleanup | `MessageRevision` / `message_revisions` | `delete_all` | ConversationContent | `Messaging.tombstone_for_erasure/3` |
| 2 | `governance.ex`, message cleanup | `Reaction` / `message_reactions` | `delete_all` | ConversationContent | `Messaging.tombstone_for_erasure/3` |
| 2 | `governance.ex`, message cleanup | `Message` / `messages` | Tombstone with `update_all` | ConversationContent | `Messaging.tombstone_for_erasure/3` |
| 2 | `governance.ex`, attachment cleanup | `Attachment` / `attachments` | Scrub and mark deleted | ConversationContent | `Attachments.mark_deleted_for_erasure/3` |
| 3 | `governance.ex`, user target | `Session` / `sessions` | Revoke with `update_all` | IdentityAccess | `Accounts.erase_user_for_governance/1` |
| 3 | `governance.ex`, user target | `Device` / `devices` | Revoke with `update_all` | IdentityAccess | `Accounts.erase_user_for_governance/1` |
| 3 | `governance.ex`, user target | `User` / `users` | Optimistic anonymization update | IdentityAccess | `Accounts.erase_user_for_governance/1` |

Owner functions must:

- reject use outside an existing transaction;
- scope every mutation by tenant and identifier;
- return counts or stable result maps, never Ecto structs;
- let Governance roll back the outer transaction on an owner error; and
- preserve the existing external-object evidence check and audit order.

## Declared read reach-through retained

Governance erasure planning and target validation still read IdentityAccess,
Conversations, and ConversationContent schemas (`User`, `Conversation`,
`Message`, and `Attachment`) under declared dependency directions. These reads
are not writes and are not approved as a permanent read-model exception. They
remain temporary contract debt until owner query DTOs can replace source-schema
reads without expanding this proof point.

## Undeclared-edge inventory

| Finding | Classification | Evidence | Correct target |
|---|---|---|---|
| Accounts → Conversations | Reverse dependency / true cycle | Tenant bootstrap is coordinated inside IdentityAccess. | Move orchestration to a declared `TenantBootstrap` application workflow. |
| Accounts → TrustGovernance | Reverse dependency / true cycle | Last-owner enforcement embeds a `DeletionRequest` subquery. | Move the cross-context invariant to an application workflow or Identity-owned pending-deletion projection. Highest cycle-breaking leverage. |
| AdmissionQuotas → Conversations | Reverse dependency plus read-model candidate | Conversation/member capacity and usage query foreign tables. | Conversations owns capacity enforcement; OperationsReadModel owns combined usage. |
| Governance → TenantAdministration | Read-projection candidate | Retention calculation directly reads `TenantSettings.default_retention_days`. | Short term: owner DTO query. Cycle-breaking target: Governance-owned projected default or tenant RetentionPolicy. |
| PasswordRecovery → Calls | Temporary audio debt / reverse command | Password reset synchronously revokes calls. | Publish an Identity access-revoked event for Calls to consume; deferred with audio work. |
| PasswordRecovery → NotificationDelivery | Reverse command / transaction orchestration debt | Recovery creates notification intent and disables push synchronously. | Transactional event/application workflow using the declared recovery event. |
| ServiceAccounts → Conversations | Reverse dependency / true cycle | Service authorization reads Conversation and Membership. | Move conversation-facing service use cases to Conversations. |

Graph simulation shows that removing Accounts → TrustGovernance offers the
largest single cycle improvement: the current seven-context SCC would shrink to
five members. That is the next cycle-focused slice after owner-write erasure.

## Transaction semantics to preserve

The deletion worker removes external objects after claiming a deletion request
and before database completion. The database cannot restore those objects.
Therefore this proof point preserves:

1. claim and immutable `DeletionExecution` projection;
2. external-object deletion;
3. exact deleted-object evidence count;
4. one Governance-owned database transaction;
5. owner-scoped database mutations;
6. DeletionRequest completion; and
7. audit append.

A late owner failure must leave the deletion request `in_progress` and roll back
all database mutations, matching current retry semantics.

## Validator limitation discovered during inventory

The current grouped-alias parser does not expand root aliases such as
`alias CommsCore.{Conversations, Messaging, Repo}`. This hides some dependency
references, including a ServiceAccounts → ConversationContent edge.

Changing that parser also changes current lexical write attribution and needs a
separate validator-hardening slice with dedicated positive/negative tests. This
proof point does not weaken or allowlist around the limitation; it records it as
control-plane debt and avoids claiming a complete acyclic graph.

## Expected result

- `direct_foreign_write`: 3 → 0 (implemented).
- Total tracked baseline: 12 → 9 (implemented).
- Governance performs no direct writes to IdentityAccess, Conversations, or
  ConversationContent tables (implemented).
- ConversationContent no longer depends on TrustGovernance for direct message
  deletion; the concrete two-file xref cycle is gone.
- The seven-context business SCC remains visible through other dependency paths.
- The next cycle-breaking priority is Accounts → TrustGovernance.
