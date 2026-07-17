# Proof Point 8 completion summary

Status: complete

Historical note: this is the verified Proof Point 8 snapshot under the
then-current detector. Proof Point 9 hardens dependency attribution, so its
current 16-finding baseline must not be compared directly to the historical
12-to-9 reduction below.

## Outcome

Proof Point 8 removed all three remaining direct foreign-write groups and one
reverse business dependency without database changes, service extraction, or
audio/video implementation changes.

| Measure | Starting baseline | Final |
|---|---:|---:|
| Total tracked boundary findings | 12 | 9 |
| `direct_foreign_write` | 3 | 0 |
| `undeclared_context_edge` | 7 | 7 |
| `adapter_schema_import` | 1 | 1 |
| `business_context_cycle` | 1 | 1 |

The remaining nine findings are still tracked debt. The seven-context business
SCC remains because alternate dependency paths still connect the same contexts;
this proof point does not claim that the SCC is resolved.

## Owner APIs

- `Accounts.erase_user_for_governance/1` owns user locking, pending-aware
  last-owner safety, optimistic anonymization, and session/device revocation.
- `Conversations.archive_for_erasure/3` owns conversation archival.
- `Conversations.remove_user_memberships_for_erasure/3` owns membership exit.
- `Messaging.tombstone_for_erasure/3` owns revision/reaction deletion and
  message tombstoning.
- `Attachments.mark_deleted_for_erasure/3` owns attachment scrubbing.

Every operation requires an existing transaction, scopes writes by tenant and
identifier, and returns counts or persistence-neutral result maps.

## Message-deletion direction

Direct user message deletion previously made Messaging call Governance while
Governance also depended on Messaging for erasure. The released path is now:

1. `CommsCore.Governance.delete_message/2` opens the transaction.
2. Messaging locks and authorizes the message inside its owner boundary.
3. Messaging passes `MessageDeletionCandidate` to the Governance policy
   callback.
4. Governance evaluates legal holds without receiving an Ecto schema.
5. Messaging updates the message, appends the outbox event, and returns
   `MessageView`.

`CommsWeb.MessageController` calls Governance for this legal-hold-aware use
case. ConversationContent no longer imports TrustGovernance, and the manifest
no longer declares that reverse dependency.

## Preserved transaction semantics

`Governance.complete_deletion_request/4` still coordinates one database
transaction after external-object evidence validation. Owner API errors are
converted to `Repo.rollback/1`; no partial IdentityAccess, Conversations,
ConversationContent, deletion-request, or audit write can commit.

The transactional outbox remains unchanged and is not used as an audit or
business-owner substitute.

## Verification

- Architecture validator tests: 38 passed.
- Architecture validator: passed with 9 tracked findings.
- Focused owner and Governance tests cover transaction enforcement, tenant
  scoping, exact counts, last-owner safety, scrubbing, legal holds, and
  end-to-end user erasure.
- `MIX_ENV=test mix compile --warnings-as-errors`: passed.
- Full umbrella suite on a fresh isolated database: 290 passed
  (`comms_observability` 1, `comms_core` 172, `comms_test_support` 1,
  `comms_integrations` 38, `comms_workers` 25, `comms_web` 53).
- Umbrella xref cycles: 10; the transient Governance/Messaging two-file cycle
  is absent.

## Residual architecture

The highest-leverage next cycle slice is the IdentityAccess →
TrustGovernance edge in `Accounts`, where lifecycle safety directly queries
`DeletionRequest`. It should be replaced by an owner-neutral workflow or
IdentityAccess-owned pending-deletion projection.

Governance erasure planning also retains declared, read-only reach-through to
foreign source schemas. Those reads are documented temporary contract debt,
not a permanent read-model exception, and should move to owner query DTOs in a
later proof point.

The audio adapter finding remains intentionally deferred and unchanged.
