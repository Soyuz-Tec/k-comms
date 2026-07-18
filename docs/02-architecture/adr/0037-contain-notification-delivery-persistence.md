# ADR-0037: Contain NotificationDelivery persistence

- **Status:** Accepted
- **Date:** 2026-07-17
- **Owners:** Architecture and engineering
- **Related decisions:** ADR-0026, ADR-0028, ADR-0032, ADR-0035

## Context

NotificationDelivery owns notification preferences, intents, attempts, and push
subscriptions, but its Ecto schemas associated directly with IdentityAccess
Tenant, User, and Device schemas. Notification fanout also queried
`Accounts.User` and `Conversations.Membership` directly. Those convenient reads
made foreign persistence models part of NotificationDelivery's compiled
implementation and left its boundaries governed by schema shape.

## Decision

NotificationDelivery stores foreign tenant, user, and device references as
scalar `Ecto.UUID` fields. Existing database foreign keys remain authoritative;
no table or migration changes are required. Associations between
NotificationDelivery-owned schemas may remain internal.

Fanout composes two owner APIs:

- `Conversations.active_member_ids/2` supplies deterministic active-member
  scalar IDs scoped by tenant and conversation.
- `Accounts.resolve_notification_recipients/2` supplies deterministic,
  tenant-scoped active-human `%Accounts.NotificationRecipient{}` contracts
  containing only the user ID and delivery email.

`CommsCore.Notifications` then applies NotificationDelivery-owned preferences
and creates intents. It must not import, query, or pattern-match foreign Ecto
schemas. Public NotificationDelivery APIs continue returning view contracts,
not persistence structs.

Push delivery uses two additional IdentityAccess owner APIs:

- `Accounts.notification_eligible_device_ids/3` returns only deterministically
  ordered device IDs for the exact tenant and active human user, excluding
  revoked or foreign devices.
- `Accounts.lock_push_registration_identity/3` requires the caller's active
  transaction and locks the eligible User row `FOR SHARE` before its eligible
  Device row `FOR SHARE`.

Push registration has one fixed lock order: NotificationDelivery acquires its
per-user capacity advisory lock, then its endpoint advisory lock, then calls
the IdentityAccess lock API (User then Device), then locks the existing
endpoint row `FOR UPDATE`, and only then expires, counts, or writes
subscriptions. This ordering is part of the concurrency contract and may not
be rearranged independently by either owner.

Destination materialization checks IdentityAccess eligibility twice: once
before decrypting the stored capability and again after the conditional
active/version update immediately before returning it. The second check also
re-reads NotificationDelivery status, version, and expiry. A concurrent
identity revocation or subscription transition visible at either gate fails
closed instead of releasing stale destination material.

The source publishes no NotificationDelivery business event today. Its proven
event inputs are `message.created.v1` and `mention.created.v1`; Oban jobs,
availability callbacks, and audit records are implementation mechanisms rather
than published domain events.

## Consequences

- NotificationDelivery retains intentional one-way dependencies on
  IdentityAccess and Conversations through stable APIs.
- Foreign table identity is explicit without duplicating table ownership.
- Fanout preserves active-human eligibility, tenant isolation, departed-member
  exclusion, deterministic ordering, and preference behavior.
- Removing an Ecto association does not remove its database constraint or
  authorize a direct foreign-table write.
- Any future recipient attribute must be added deliberately to the
  IdentityAccess-owned contract rather than recovered through schema access.

## Alternatives considered

| Alternative | Rejection reason |
|---|---|
| Keep read-only foreign associations | Read-only Ecto reach-through still couples compilation and queries to another owner's persistence model. |
| Copy user or membership schemas into Notifications | A second schema would create duplicate ownership rather than containment. |
| Move notification tables into IdentityAccess or Conversations | Notification preferences and delivery lifecycle form a coherent existing owner and do not require a table move. |
| Introduce a shared recipient schema or shared kernel | It would hide ownership and recreate the coupling under a neutral name. |

## Validation

- NotificationDelivery production modules contain no reference to
  `Accounts.User`, `Accounts.Device`, `Accounts.Tenant`, or
  `Conversations.Membership`.
- Notification schemas represent foreign IDs with scalar `Ecto.UUID` fields.
- Recipient and active-member owner APIs enforce tenant scope and deterministic
  output, including departed and cross-tenant cases.
- Push registration fails outside a transaction, locks User before Device with
  `FOR SHARE`, and preserves the documented advisory/identity lock order.
- Push candidate selection and both materialization eligibility checks reject
  inactive or service users, revoked or foreign devices, and stale
  subscriptions.
- Notification behavioral tests preserve message, mention, preference, push,
  and recovery behavior.
- Architecture validation removes the corresponding foreign-schema and
  undeclared-edge fingerprints without adding a replacement violation.
