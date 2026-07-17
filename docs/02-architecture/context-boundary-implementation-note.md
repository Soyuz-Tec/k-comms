# Context-boundary proof-point implementation note

Apply these changes only after the manifest and baseline-aware validator are in
CI. They prove ownership and contract rules without beginning a broad move.

## 1. Canonical users ownership — completed 2026-07-16

`identity_access` owns `users`; `CommsCore.Accounts.User` is the current
canonical schema. `CommsCore.ServiceAccounts.ServiceUser` has been removed; its
queries, pattern matches, association, and focused tests now use the canonical
schema inside the shared `identity_access` owner boundary. The service-only
creation changeset is defined on that canonical schema, while service-account
behavior remains behind `CommsCore.ServiceAccounts`. The validator now
discovers one schema for `users`, and the duplicate-table baseline fingerprint
has been removed.

## 2. Internal audit persistence — completed 2026-07-16

`audit` owns `audit_events`; `CommsCore.Audit.AuditEvent` is the sole canonical
schema and is restricted to the `CommsCore.Audit` implementation namespace.
`CommsCore.Audit.record/1` validates and persists audit commands, while
`CommsCore.Audit.append/2` preserves atomic composition with `Ecto.Multi`.
Callers receive `CommsCore.Audit.Event` projections or
`CommsCore.Audit.Error` values, never Ecto schemas or changesets. Audit reads
are tenant-scoped. Web presenters now consume the public event projection, and
all business contexts write through the facade. The manifest and validator
enforce the owner-internal schema restriction, and only the Audit
implementation references `AuditEvent` in production.

Do not combine either proof point with namespace renames, frontend changes, or
unrelated context moves.

## 3. Messaging and Attachments ownership — completed 2026-07-16

Messaging and Attachments remain one `conversation_content` boundary because
attachment claiming is part of the message-publication transaction and linked
attachment authorization follows the message conversation. Messaging is the
publication orchestrator and calls `Attachments.attach_ready/4` with IDs;
Attachments does not import Messaging schemas or implementation modules.

Unused child-to-parent Ecto associations were replaced by foreign-key ID fields
without changing the database. Public callers now receive Message, Reaction,
Attachment, and ScanAttempt view contracts rather than persistence structs.
The validator enforces the one-way internal namespace rule, and the former
five-file Messaging/Attachments xref cycle has been removed.

The later ADR-0040 containment cut also replaces every foreign association in
the Message, Mention, Revision, Reaction, Attachment, and ScanAttempt schemas
with scalar IDs while preserving useful same-owner associations. Messaging and
Attachments consume the narrow `ConversationContentPolicy` projection rather
than a broad tenant-capability map. Restore verification is exposed through
the Attachments facade with Ecto-free candidate, context, identity, and report
contracts; Release no longer imports the internal restore implementation.
`Attachments.attach_ready/4` now requires the message-publication transaction.
The reviewed baseline transition removes exactly thirteen findings, from 59 to
46, without adding a migration or architecture exception.

## 4. Notification delivery consolidation — completed 2026-07-16

Notification preferences, intents, delivery attempts, in-app state, and browser
push subscriptions remain one `notification_delivery` boundary with
`CommsCore.Notifications` as its sole public facade. The former top-level
`CommsCore.InAppNotifications` and `CommsCore.PushSubscriptions` modules were
folded into owner-internal implementations and are now retired by the validator.

Controllers and workers receive redacted views, a content-free availability
signal, or an inspect-redacted delivery command instead of Ecto schemas. The
database and delivery transactions are unchanged. The Intent/Attempt reverse
association was removed because no caller used it, eliminating the compiled
notification schema cycle. At this proof point, the remaining
IdentityAccess/NotificationDelivery edge stayed tracked. ADR-0032 resolves it
through an IdentityAccess-owned synchronous port; asynchronous lifecycle events
were rejected because they would change recovery and revocation transaction
semantics.

## 5. Released-adapter decoupling — completed 2026-07-16

Web controllers, presenters, and non-audio workers now consume owner-declared
views, authentication results, access contexts, capability claims, dispatch
requests, deletion executions, and outbox event envelopes. Webhook claim tokens,
dispatch secrets/bodies, deletion object locators, and outbox payloads are
inspect-redacted. Webhook materialization still locks the endpoint before the
delivery and decrypts the exact persisted secret version immediately before
dispatch.

The validator rejects adapter-side `Ecto.Changeset` dependencies, missing public
contracts, and contracts implemented as Ecto schemas. The tracked baseline fell
from 56 to 36 findings: 18 non-audio adapter schema imports and two direct
`OutboxEvent` cross-context write fingerprints were removed. The one remaining
adapter schema import is the explicitly deferred read-only `AudioCall` presenter
path; Proof Point 5 did not modify audio/video code.

## 6. Identity notification lifecycle port — completed 2026-07-17

IdentityAccess owns Ecto-free `NotificationCommand`, `NotificationReceipt`, and
`NotificationPort` contracts. The composition root binds
`CommsCore.Notifications` as the implementation. Accounts and PasswordRecovery
use only the port, while the implementation requires and reuses the caller's
active repository transaction.

The verified cut removes the aggregate
`identity_access -> notification_delivery` edge without changing the recovery
intent, Oban job, audit correlation, or push-revocation atomicity. The
composition binding and absence of direct Notifications calls are validator
requirements so runtime indirection cannot become an ungoverned service
locator.

The regenerated baseline contains 102 findings and 11 undeclared edges. The
principal SCC now contains Calls, Conversations, IdentityAccess, and
TenantAdministration, with fingerprint `d900c7783f86b39a`. No identity recovery
event or outbox flow was introduced; the manifest no longer claims the
unimplemented recovery event. See ADR-0032 and
`proof-point-11-identity-notification-port.md`.

## 7. Conversation admission owner direction — completed 2026-07-17

TenantAdministration owns the shared tenant admission lock and publishes an
Ecto-free `AdmissionPolicy`. Conversations now observes its own Conversation
and Membership tables after acquiring that policy and passes only scalar counts
to the quota decisions. Admission lock, count, decision, and write remain in
the existing caller-owned transaction.

The former cross-owner quota aggregate is composed by the read-only Operations
context from exact owner queries. The admin HTTP response is unchanged, no
source-table grant was added, and no business context depends on Operations.

The regenerated baseline contains 99 findings. The
`tenant_administration -> conversations` edge and both foreign conversation
schema fingerprints are gone. The principal SCC still contains the same four
contexts, but now has eleven internal relationships with fingerprint
`127209a1d6c0c922`. Notification eligibility debt and all deferred audio/video
work remain unchanged. See ADR-0033 and
`proof-point-12-conversation-admission-owner-direction.md`.

## 8. Identity and conversation owner direction — completed 2026-07-17

IdentityAccess owns the Ecto-schema-free `InitialConversationCommand`,
`InitialConversationReceipt`, and `ConversationBootstrapPort` contracts.
Conversations is the sole configured provider and executes initial-channel
create/fetch work on the caller's active repository transaction. Accounts no
longer imports Conversations or re-projects its public view. The typed receipt
contains only scalar bootstrap projection fields, is validated against the
command, and cannot carry an Ecto schema. Release retries accept only one
unarchived General channel with an active owner membership.

ServiceAccounts now validates only durable service identity and scope.
Conversations owns service directory listing plus active-membership and
non-archived-conversation policy. Messaging keeps its preflight and
in-transaction authorization checks by calling that owner facade.

The regenerated baseline contains 95 findings. Both
`identity_access -> conversations` edge fingerprints and the two foreign
Conversation/Membership schema fingerprints are gone. The principal SCC still
contains the same four contexts, but now has ten compiled internal
relationships with fingerprint `75826183c4276dbe`. The manifest separately
declares the synchronous runtime collaboration. The port binding, exact
operation and caller sets, owner APIs, adapter exclusion, and graph delta are
CI regressions. See ADR-0034 and
`proof-point-13-identity-conversation-owner-direction.md`.
