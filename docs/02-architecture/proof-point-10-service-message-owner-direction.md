# Proof Point 10: service-message owner direction

Status: complete and verified on 2026-07-17.

This is the repository-effective tenth proof point. It implements the
request-numbered Proof Point 8 without renaming or overwriting the existing
Proof Point 8 and 9 records.

The graph and baseline counts below are the verified Proof Point 10 snapshot.
Proof Point 11 subsequently targets IdentityAccess to NotificationDelivery;
ADR-0032 and `proof-point-11-identity-notification-port.md` define that cut and
its acceptance targets.

## Outcome

The selected dependency was:

```text
IdentityAccess -> ConversationContent
```

It was a workflow-orchestration and convenience-facade edge, not a direct
foreign-table write. `CommsCore.ServiceAccounts` delegated message history,
message creation, and search to `CommsCore.Messaging` and carried content
authorization callbacks and attachment policy in the identity facade.

ConversationContent now owns those workflows through the public Messaging
facade. Messaging calls the stable
`CommsCore.ServiceAccounts.authorize_service/3` contract, establishing the
already-declared one-way direction:

```text
ConversationContent -> IdentityAccess
```

No persistence schema crosses the new facade. Web callers receive
`CommsCore.Messaging.MessageView` projections.

## Candidate inventory and priority

| Priority | Candidate edge | Production locations | Classification | Graph result | Reason |
|---:|---|---|---|---|---|
| 1 | IdentityAccess to ConversationContent | `service_accounts.ex`, service message/search controllers | Workflow orchestration and convenience facade | SCC shrinks from 6 to 5 | One core source and two adapter callers; behavior can move to the natural content owner. |
| 2 | IdentityAccess to NotificationDelivery | `accounts.ex`, `password_recovery.ex` | Security-sensitive workflow orchestration | SCC shrinks from 6 to 5 | Same graph leverage, but changes synchronous recovery, push cleanup, audit correlation, and transaction semantics. |
| 3 | NotificationDelivery to TenantAdministration | Four Notification Ecto schemas with unused tenant associations | Foreign-schema association | SCC remains at 6 | Mechanically small and removes several findings, but does not reduce SCC membership. |
| 4 | TenantAdministration to Conversations | `admission_quotas.ex` | Reverse decision-bearing read and read-through | SCC remains at 6 | Requires moving enforcement and combined reporting while preserving admission locking. |
| 5 | Conversations or TenantAdministration to Calls | `conversations.ex`, `administration.ex` | Transactional security workflow | SCC remains at 6 for a single edge | Touches deferred audio/video and same-transaction admission revocation. |

Exhaustive single-edge simulation showed that only the first two candidates
remove a context from the six-member SCC. The first candidate was selected
because it is the smaller behavior-preserving change.

## Exact change sequence

1. Inventory every edge in the six-context SCC and simulate each single-edge
   removal.
2. Select IdentityAccess to ConversationContent and classify the existing
   ServiceAccounts functions as owner-orchestration debt.
3. Add owner-side service history, send, and search APIs to
   `CommsCore.Messaging`.
4. Move service attachment policy, trusted sender attribute construction, and
   transaction-time authorization callbacks to Messaging.
5. Change the service message and service search controllers to call Messaging.
6. Remove the three content functions and all Messaging/Attachments references
   from ServiceAccounts.
7. Update focused behavior tests and add a repository architecture regression.
8. Add the namespace rule, regenerate the boundary baseline, and record this
   decision in ADR-0031.

## Implementation by file

### `apps/comms_core/lib/comms_core/messaging.ex`

Added:

- `list_service_history/3`;
- `accept_service_message_with_status/3`; and
- `search_for_service/3`.

The functions authorize through ServiceAccounts, return `MessageView`
projections, preserve search limits, reject service attachments, and force the
authenticated tenant, conversation, user, and device identifiers. Message
acceptance retains the authorization callback inside the existing Messaging
transaction, including duplicate replay.

### `apps/comms_core/lib/comms_core/service_accounts.ex`

Removed:

- `list_messages/3`;
- `send_message/3`;
- `search/3`;
- the Messaging dependency;
- service-message authorization callbacks; and
- attachment validation.

Retained `authorize_service/3` and `list_conversations/1`. Direct Conversation
and Membership access remains an explicit, separately tracked
IdentityAccess-to-Conversations defect.

### Web controllers

`service_message_controller.ex` and `service_search_controller.ex` now call
`CommsCore.Messaging`. Routes, payloads, status codes, broadcasting, and
presenters are unchanged. `service_conversation_controller.ex` remains on
ServiceAccounts because conversation-directory access was intentionally not
part of this cut.

### Tests and control plane

`service_accounts_test.exs` now exercises content operations through Messaging
and explicitly protects the service attachment rejection.

`context-boundaries.yaml` forbids ServiceAccounts from depending on Messaging
or Attachments. `test_validate_architecture.py` verifies the manifest rule,
owner APIs, absence of the reverse dependency, and controller direction.

The generated baseline and violation report remove edge fingerprint
`f2a0e45878ec6f32`. The old six-context SCC fingerprint
`88c8caffbe1ebfb9` is replaced by five-context fingerprint
`ed93d60bb448290c`.

## Architecture delta

| Measure | Before | After |
|---|---:|---:|
| Tracked boundary findings | 105 | 104 |
| Undeclared edge fingerprints | 14 | 13 |
| Business SCC size | 6 contexts | 5 contexts |
| Internal edges in the principal SCC | 20 | 16 |
| Foreign-schema findings | 83 | 83 |
| Internal-schema findings | 6 | 6 |
| Adapter-schema findings | 1 | 1 |

The remaining SCC contains Calls, Conversations, IdentityAccess,
NotificationDelivery, and TenantAdministration. ConversationContent is now an
acyclic singleton in the business graph.

## Residual inventory

The 13 temporary undeclared edge fingerprints are:

| Location | Residual direction |
|---|---|
| `accounts.ex` | IdentityAccess to Calls, Conversations, and NotificationDelivery |
| `administration.ex` | TenantAdministration to Calls |
| `admission_quotas.ex` | TenantAdministration to Conversations |
| `conversations.ex` | Conversations to Calls |
| Four Notification schemas | NotificationDelivery to TenantAdministration |
| `password_recovery.ex` | IdentityAccess to Calls and NotificationDelivery |
| `service_accounts.ex` | IdentityAccess to Conversations |

The 83 foreign-schema, 6 internal-schema, and deferred audio adapter findings
remain unchanged. There is no new read exception or temporary exception for
this proof point.

## Verification

- Targeted service-account core tests: 4 passed.
- Service-account web controller tests: 2 passed.
- Full umbrella ExUnit suite: 298 passed.
- Architecture validator tests: 72 passed.
- Architecture validation: passed with exactly 104 tracked findings.
- Documentation validation: passed for 185 Markdown files.
- `mix format --check-formatted` and warnings-as-errors compilation: passed.
- Mix xref: 229 files, 85 compile edges, 142 export edges, 532 runtime edges,
  and 10 file-level cycles.
- Python compilation and targeted `git diff --check`: passed.

No database migration, microservice extraction, shared workflow kernel,
database rewrite, or audio/video change is part of this proof point.
