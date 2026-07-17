# Context-boundary violation baseline

Generated from `scripts/validate_architecture.py --write-boundary-baseline`.
Existing fingerprints are migration debt. Relative to the checked-in baseline,
new, changed, or resolved fingerprints fail CI; baseline edits require architecture review.

Total tracked violations: **103**.

## adapter_schema_import (1)

| Fingerprint | Location | Evidence |
|---|---|---|
| `7a1ffc82ac877370` | `apps/comms_web/lib/comms_web/presenter.ex` | adapter references internal Ecto schema CommsCore.AudioCalls.AudioCall |

## business_context_cycle (1)

| Fingerprint | Location | Evidence |
|---|---|---|
| `a26844eb317ed35d` | `docs/02-architecture/context-boundaries.yaml` | members: authorization_kernel, calls, conversations, identity_access, tenant_administration; edges: authorization_kernel->conversations, authorization_kernel->identity_access, authorization_kernel->tenant_administration, calls->authorization_kernel, calls->conversations, calls->identity_access, calls->tenant_administration, conversations->calls, conversations->identity_access, conversations->tenant_administration, identity_access->calls, identity_access->tenant_administration, tenant_administration->calls |

## foreign_schema_import (83)

| Fingerprint | Location | Evidence |
|---|---|---|
| `46833d9e4f37a9f4` | `apps/comms_core/lib/comms_core/accounts.ex` | CommsCore.Accounts references owner-internal schema CommsCore.Accounts.Tenant |
| `2a53bebf9a2c2b68` | `apps/comms_core/lib/comms_core/accounts/device.ex` | CommsCore.Accounts.Device references owner-internal schema CommsCore.Accounts.Tenant |
| `42cd72ee581f329d` | `apps/comms_core/lib/comms_core/accounts/password_recovery_request.ex` | CommsCore.Accounts.PasswordRecoveryRequest references owner-internal schema CommsCore.Accounts.Tenant |
| `24d261bf4611f799` | `apps/comms_core/lib/comms_core/accounts/platform_role_grant.ex` | CommsCore.Accounts.PlatformRoleGrant references owner-internal schema CommsCore.Accounts.Tenant |
| `2239525a78f246a4` | `apps/comms_core/lib/comms_core/accounts/session.ex` | CommsCore.Accounts.Session references owner-internal schema CommsCore.Accounts.Tenant |
| `9c00206437b708a1` | `apps/comms_core/lib/comms_core/accounts/socket_ticket.ex` | CommsCore.Accounts.SocketTicket references owner-internal schema CommsCore.Accounts.Tenant |
| `6e01f546438ba1e0` | `apps/comms_core/lib/comms_core/accounts/user.ex` | CommsCore.Accounts.User references owner-internal schema CommsCore.Accounts.Tenant |
| `281d9add61ab8c61` | `apps/comms_core/lib/comms_core/attachments/attachment.ex` | CommsCore.Attachments.Attachment references owner-internal schema CommsCore.Accounts.Tenant |
| `4d0c0c815493288e` | `apps/comms_core/lib/comms_core/attachments/attachment.ex` | CommsCore.Attachments.Attachment references owner-internal schema CommsCore.Accounts.User |
| `7ac0c7ca4d4d6af3` | `apps/comms_core/lib/comms_core/attachments/scan_attempt.ex` | CommsCore.Attachments.ScanAttempt references owner-internal schema CommsCore.Accounts.Tenant |
| `fc1a11f2a5f8452a` | `apps/comms_core/lib/comms_core/audio_calls.ex` | CommsCore.AudioCalls references owner-internal schema CommsCore.Accounts.Session |
| `8ee1149661d778c8` | `apps/comms_core/lib/comms_core/audio_calls.ex` | CommsCore.AudioCalls references owner-internal schema CommsCore.Accounts.Tenant |
| `605ae97a5fa655cc` | `apps/comms_core/lib/comms_core/audio_calls.ex` | CommsCore.AudioCalls references owner-internal schema CommsCore.Conversations.Conversation |
| `7fbfb2c4017910ce` | `apps/comms_core/lib/comms_core/audio_calls.ex` | CommsCore.AudioCalls references owner-internal schema CommsCore.Conversations.Membership |
| `440a0becf16cccb8` | `apps/comms_core/lib/comms_core/audio_calls/audio_call.ex` | CommsCore.AudioCalls.AudioCall references owner-internal schema CommsCore.Accounts.Tenant |
| `9fa2f7bb1abcc6b0` | `apps/comms_core/lib/comms_core/audio_calls/audio_call.ex` | CommsCore.AudioCalls.AudioCall references owner-internal schema CommsCore.Accounts.User |
| `6af6e9564cd1b152` | `apps/comms_core/lib/comms_core/audio_calls/audio_call.ex` | CommsCore.AudioCalls.AudioCall references owner-internal schema CommsCore.Conversations.Conversation |
| `66c2fbf2a79936f4` | `apps/comms_core/lib/comms_core/audio_calls/audio_call_participant.ex` | CommsCore.AudioCalls.AudioCallParticipant references owner-internal schema CommsCore.Accounts.Device |
| `7c601f7c21a5fe6c` | `apps/comms_core/lib/comms_core/audio_calls/audio_call_participant.ex` | CommsCore.AudioCalls.AudioCallParticipant references owner-internal schema CommsCore.Accounts.Session |
| `7e866a84330fe233` | `apps/comms_core/lib/comms_core/audio_calls/audio_call_participant.ex` | CommsCore.AudioCalls.AudioCallParticipant references owner-internal schema CommsCore.Accounts.Tenant |
| `96d281b6465f8b8b` | `apps/comms_core/lib/comms_core/audio_calls/audio_call_participant.ex` | CommsCore.AudioCalls.AudioCallParticipant references owner-internal schema CommsCore.Accounts.User |
| `6b641d47b77c08c7` | `apps/comms_core/lib/comms_core/audio_calls/audio_call_participant.ex` | CommsCore.AudioCalls.AudioCallParticipant references owner-internal schema CommsCore.Conversations.Conversation |
| `8dd4f3b5e1378ffb` | `apps/comms_core/lib/comms_core/authorization/database.ex` | CommsCore.Authorization.Database references owner-internal schema CommsCore.Accounts.Device |
| `db68fcb3dac3ef04` | `apps/comms_core/lib/comms_core/authorization/database.ex` | CommsCore.Authorization.Database references owner-internal schema CommsCore.Accounts.Session |
| `d312276f5a39310f` | `apps/comms_core/lib/comms_core/authorization/database.ex` | CommsCore.Authorization.Database references owner-internal schema CommsCore.Accounts.Tenant |
| `de83107f64cbc690` | `apps/comms_core/lib/comms_core/authorization/database.ex` | CommsCore.Authorization.Database references owner-internal schema CommsCore.Accounts.User |
| `99cd7470375bce8f` | `apps/comms_core/lib/comms_core/authorization/database.ex` | CommsCore.Authorization.Database references owner-internal schema CommsCore.Administration.TenantSettings |
| `e3c6574035e85b56` | `apps/comms_core/lib/comms_core/authorization/database.ex` | CommsCore.Authorization.Database references owner-internal schema CommsCore.Conversations.Conversation |
| `c94c7774541553d1` | `apps/comms_core/lib/comms_core/authorization/database.ex` | CommsCore.Authorization.Database references owner-internal schema CommsCore.Conversations.Membership |
| `8e1a8065ef4e942a` | `apps/comms_core/lib/comms_core/conversations.ex` | CommsCore.Conversations references owner-internal schema CommsCore.Accounts.User |
| `01480f3bb95a9c16` | `apps/comms_core/lib/comms_core/conversations/conversation.ex` | CommsCore.Conversations.Conversation references owner-internal schema CommsCore.Accounts.Tenant |
| `b868ec00572fc392` | `apps/comms_core/lib/comms_core/conversations/conversation.ex` | CommsCore.Conversations.Conversation references owner-internal schema CommsCore.Accounts.User |
| `e62a5587406838f2` | `apps/comms_core/lib/comms_core/conversations/membership.ex` | CommsCore.Conversations.Membership references owner-internal schema CommsCore.Accounts.Tenant |
| `fc4e10c723ffa345` | `apps/comms_core/lib/comms_core/conversations/membership.ex` | CommsCore.Conversations.Membership references owner-internal schema CommsCore.Accounts.User |
| `b57d207c73d50d3c` | `apps/comms_core/lib/comms_core/conversations/projector.ex` | CommsCore.Conversations.Projector references owner-internal schema CommsCore.Accounts.User |
| `b9eb079551e887da` | `apps/comms_core/lib/comms_core/governance.ex` | CommsCore.Governance references owner-internal schema CommsCore.Accounts.User |
| `0ce8e87873a601ba` | `apps/comms_core/lib/comms_core/governance.ex` | CommsCore.Governance references owner-internal schema CommsCore.Attachments.Attachment |
| `6649c5c8afcc1451` | `apps/comms_core/lib/comms_core/governance.ex` | CommsCore.Governance references owner-internal schema CommsCore.Conversations.Conversation |
| `fbe03345ca68ae0e` | `apps/comms_core/lib/comms_core/governance.ex` | CommsCore.Governance references owner-internal schema CommsCore.Messaging.Message |
| `3fb3b9127af11031` | `apps/comms_core/lib/comms_core/governance/deletion_request.ex` | CommsCore.Governance.DeletionRequest references owner-internal schema CommsCore.Accounts.Tenant |
| `fd674ae8b306fa26` | `apps/comms_core/lib/comms_core/governance/deletion_request.ex` | CommsCore.Governance.DeletionRequest references owner-internal schema CommsCore.Accounts.User |
| `9dde14a81ec1bedf` | `apps/comms_core/lib/comms_core/governance/deletion_request.ex` | CommsCore.Governance.DeletionRequest references owner-internal schema CommsCore.Conversations.Conversation |
| `4024443a7852f0ba` | `apps/comms_core/lib/comms_core/governance/deletion_request.ex` | CommsCore.Governance.DeletionRequest references owner-internal schema CommsCore.Messaging.Message |
| `b9d112a8c4fed848` | `apps/comms_core/lib/comms_core/governance/legal_hold.ex` | CommsCore.Governance.LegalHold references owner-internal schema CommsCore.Accounts.Tenant |
| `02a344526496fff1` | `apps/comms_core/lib/comms_core/governance/legal_hold.ex` | CommsCore.Governance.LegalHold references owner-internal schema CommsCore.Accounts.User |
| `39d2b55a0831efb3` | `apps/comms_core/lib/comms_core/governance/legal_hold.ex` | CommsCore.Governance.LegalHold references owner-internal schema CommsCore.Conversations.Conversation |
| `91455ba0a93f09b2` | `apps/comms_core/lib/comms_core/governance/retention_policy.ex` | CommsCore.Governance.RetentionPolicy references owner-internal schema CommsCore.Accounts.Tenant |
| `6b606b572e7256e4` | `apps/comms_core/lib/comms_core/governance/retention_policy.ex` | CommsCore.Governance.RetentionPolicy references owner-internal schema CommsCore.Conversations.Conversation |
| `c06055a43f05a1f7` | `apps/comms_core/lib/comms_core/integrations/webhook_delivery.ex` | CommsCore.Integrations.WebhookDelivery references owner-internal schema CommsCore.Events.OutboxEvent |
| `b55f1875cf2b64d8` | `apps/comms_core/lib/comms_core/messaging/message.ex` | CommsCore.Messaging.Message references owner-internal schema CommsCore.Accounts.Device |
| `f1940a85836a5231` | `apps/comms_core/lib/comms_core/messaging/message.ex` | CommsCore.Messaging.Message references owner-internal schema CommsCore.Accounts.Tenant |
| `0bb3a37c40cc67ed` | `apps/comms_core/lib/comms_core/messaging/message.ex` | CommsCore.Messaging.Message references owner-internal schema CommsCore.Accounts.User |
| `7189e4399b7315ba` | `apps/comms_core/lib/comms_core/messaging/message.ex` | CommsCore.Messaging.Message references owner-internal schema CommsCore.Conversations.Conversation |
| `e7095da760d0066e` | `apps/comms_core/lib/comms_core/messaging/message_mention.ex` | CommsCore.Messaging.MessageMention references owner-internal schema CommsCore.Accounts.Tenant |
| `7cefa81ef6dff66b` | `apps/comms_core/lib/comms_core/messaging/message_mention.ex` | CommsCore.Messaging.MessageMention references owner-internal schema CommsCore.Accounts.User |
| `0eed2537c58046a8` | `apps/comms_core/lib/comms_core/messaging/message_revision.ex` | CommsCore.Messaging.MessageRevision references owner-internal schema CommsCore.Accounts.Tenant |
| `1e36cf5947105a60` | `apps/comms_core/lib/comms_core/messaging/message_revision.ex` | CommsCore.Messaging.MessageRevision references owner-internal schema CommsCore.Accounts.User |
| `00fed2fc66ac6b5f` | `apps/comms_core/lib/comms_core/messaging/reaction.ex` | CommsCore.Messaging.Reaction references owner-internal schema CommsCore.Accounts.Tenant |
| `f30df696bf8e3c3c` | `apps/comms_core/lib/comms_core/messaging/reaction.ex` | CommsCore.Messaging.Reaction references owner-internal schema CommsCore.Accounts.User |
| `931b221d49955995` | `apps/comms_core/lib/comms_core/moderation.ex` | CommsCore.Moderation references owner-internal schema CommsCore.Accounts.User |
| `5eb997f15e01638a` | `apps/comms_core/lib/comms_core/moderation.ex` | CommsCore.Moderation references owner-internal schema CommsCore.Conversations.Conversation |
| `21514fd0a6bcff09` | `apps/comms_core/lib/comms_core/moderation.ex` | CommsCore.Moderation references owner-internal schema CommsCore.Messaging.Message |
| `ca44a9b4fcec3602` | `apps/comms_core/lib/comms_core/moderation/moderation_action.ex` | CommsCore.Moderation.ModerationAction references owner-internal schema CommsCore.Accounts.Tenant |
| `15be140bfa74d0b1` | `apps/comms_core/lib/comms_core/moderation/moderation_action.ex` | CommsCore.Moderation.ModerationAction references owner-internal schema CommsCore.Accounts.User |
| `a0a0818fd52b5b6f` | `apps/comms_core/lib/comms_core/moderation/moderation_case.ex` | CommsCore.Moderation.ModerationCase references owner-internal schema CommsCore.Accounts.Tenant |
| `58b919fe1323a5b8` | `apps/comms_core/lib/comms_core/moderation/moderation_case.ex` | CommsCore.Moderation.ModerationCase references owner-internal schema CommsCore.Accounts.User |
| `ddc7d93ab9361594` | `apps/comms_core/lib/comms_core/moderation/moderation_case.ex` | CommsCore.Moderation.ModerationCase references owner-internal schema CommsCore.Conversations.Conversation |
| `6ec655792ddf69c9` | `apps/comms_core/lib/comms_core/moderation/moderation_case.ex` | CommsCore.Moderation.ModerationCase references owner-internal schema CommsCore.Messaging.Message |
| `eb5d23e247bfa767` | `apps/comms_core/lib/comms_core/notifications.ex` | CommsCore.Notifications references owner-internal schema CommsCore.Accounts.User |
| `84a5b72a3c38e9e8` | `apps/comms_core/lib/comms_core/notifications.ex` | CommsCore.Notifications references owner-internal schema CommsCore.Conversations.Membership |
| `1e1d10760987004e` | `apps/comms_core/lib/comms_core/notifications/attempt.ex` | CommsCore.Notifications.Attempt references owner-internal schema CommsCore.Accounts.Tenant |
| `044ad0a09865bdff` | `apps/comms_core/lib/comms_core/notifications/intent.ex` | CommsCore.Notifications.Intent references owner-internal schema CommsCore.Accounts.Tenant |
| `af08c6b0f0c514cf` | `apps/comms_core/lib/comms_core/notifications/intent.ex` | CommsCore.Notifications.Intent references owner-internal schema CommsCore.Accounts.User |
| `1ee6ff99500eaa19` | `apps/comms_core/lib/comms_core/notifications/preference.ex` | CommsCore.Notifications.Preference references owner-internal schema CommsCore.Accounts.Tenant |
| `87dbcd607e0b12b6` | `apps/comms_core/lib/comms_core/notifications/preference.ex` | CommsCore.Notifications.Preference references owner-internal schema CommsCore.Accounts.User |
| `4f6b857dddd8871e` | `apps/comms_core/lib/comms_core/notifications/push_subscription.ex` | CommsCore.Notifications.PushSubscription references owner-internal schema CommsCore.Accounts.Device |
| `7df5d18a55a8e299` | `apps/comms_core/lib/comms_core/notifications/push_subscription.ex` | CommsCore.Notifications.PushSubscription references owner-internal schema CommsCore.Accounts.Tenant |
| `6b82842b18ee1b7c` | `apps/comms_core/lib/comms_core/notifications/push_subscription.ex` | CommsCore.Notifications.PushSubscription references owner-internal schema CommsCore.Accounts.User |
| `474e0a1759a65216` | `apps/comms_core/lib/comms_core/notifications/push_subscriptions.ex` | CommsCore.Notifications.PushSubscriptions references owner-internal schema CommsCore.Accounts.Device |
| `c3db96cf85cb9698` | `apps/comms_core/lib/comms_core/notifications/push_subscriptions.ex` | CommsCore.Notifications.PushSubscriptions references owner-internal schema CommsCore.Accounts.User |
| `c3292521cd5c5918` | `apps/comms_core/lib/comms_core/password_recovery.ex` | CommsCore.PasswordRecovery references owner-internal schema CommsCore.Accounts.Tenant |
| `82083a1e5dce0f4c` | `apps/comms_core/lib/comms_core/service_accounts.ex` | CommsCore.ServiceAccounts references owner-internal schema CommsCore.Accounts.Tenant |
| `3d08a6a84ca380ce` | `apps/comms_core/lib/comms_core/service_accounts/service_account.ex` | CommsCore.ServiceAccounts.ServiceAccount references owner-internal schema CommsCore.Accounts.Tenant |

## internal_schema_access (6)

| Fingerprint | Location | Evidence |
|---|---|---|
| `4791022b743e09fb` | `apps/comms_core/lib/comms_core/admission_quotas.ex` | CommsCore.AdmissionQuotas references owner-internal schema CommsCore.Administration.TenantSettings |
| `8ab1b96f6b510f3d` | `apps/comms_core/lib/comms_core/outbox.ex` | CommsCore.Outbox references owner-internal schema CommsCore.Events.OutboxEvent |
| `242e1087dab4d610` | `apps/comms_core/lib/comms_core/password_recovery.ex` | CommsCore.PasswordRecovery references owner-internal schema CommsCore.Accounts.Device |
| `830bbf4ebd3732c3` | `apps/comms_core/lib/comms_core/password_recovery.ex` | CommsCore.PasswordRecovery references owner-internal schema CommsCore.Accounts.PasswordRecoveryRequest |
| `b881cf0b24fc1a13` | `apps/comms_core/lib/comms_core/password_recovery.ex` | CommsCore.PasswordRecovery references owner-internal schema CommsCore.Accounts.Session |
| `537281a03df0f98f` | `apps/comms_core/lib/comms_core/password_recovery.ex` | CommsCore.PasswordRecovery references owner-internal schema CommsCore.Accounts.User |

## undeclared_context_edge (12)

| Fingerprint | Location | Evidence |
|---|---|---|
| `889ca078f04b8132` | `apps/comms_core/lib/comms_core/accounts.ex` | identity_access -> calls through CommsCore.AudioCalls |
| `0e985916a4de06ec` | `apps/comms_core/lib/comms_core/administration.ex` | tenant_administration -> calls through CommsCore.AudioCalls |
| `0189e4bac08f3c6e` | `apps/comms_core/lib/comms_core/audio_calls.ex` | calls -> authorization_kernel through CommsCore.Authorization |
| `4f52bd7c42b47a5d` | `apps/comms_core/lib/comms_core/authorization/database.ex` | authorization_kernel -> conversations through CommsCore.Conversations, CommsCore.Conversations.Conversation, CommsCore.Conversations.Membership |
| `47659f71148ad7cd` | `apps/comms_core/lib/comms_core/authorization/database.ex` | authorization_kernel -> identity_access through CommsCore.Accounts, CommsCore.Accounts.Device, CommsCore.Accounts.Session, CommsCore.Accounts.User |
| `22d29c8a33ec3581` | `apps/comms_core/lib/comms_core/authorization/database.ex` | authorization_kernel -> tenant_administration through CommsCore.Accounts.Tenant, CommsCore.Administration.TenantSettings |
| `bec8b11dfcf061c7` | `apps/comms_core/lib/comms_core/conversations.ex` | conversations -> calls through CommsCore.AudioCalls |
| `e80e50669f5d670e` | `apps/comms_core/lib/comms_core/notifications/attempt.ex` | notification_delivery -> tenant_administration through CommsCore.Accounts.Tenant |
| `a34ca28aa15ea541` | `apps/comms_core/lib/comms_core/notifications/intent.ex` | notification_delivery -> tenant_administration through CommsCore.Accounts.Tenant |
| `4cc7ca468d6af0e4` | `apps/comms_core/lib/comms_core/notifications/preference.ex` | notification_delivery -> tenant_administration through CommsCore.Accounts.Tenant |
| `c0c0fa81093ad554` | `apps/comms_core/lib/comms_core/notifications/push_subscription.ex` | notification_delivery -> tenant_administration through CommsCore.Accounts.Tenant |
| `7c47ce0ca3e555a9` | `apps/comms_core/lib/comms_core/password_recovery.ex` | identity_access -> calls through CommsCore.AudioCalls |

## Context dependency graphs

### Compiled graph

Static production module references (source owner -> referenced owner).

| Source | Targets |
|---|---|
| `authorization_kernel` | `conversations`, `identity_access`, `tenant_administration` |
| `calls` | `audit`, `authorization_kernel`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversation_content` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversations` | `audit`, `calls`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `identity_access` | `audit`, `calls`, `tenant_administration` |
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `tenant_administration` | `audit`, `calls` |
| `trust_governance` | `audit`, `calls`, `conversation_content`, `conversations`, `identity_access`, `tenant_administration` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **45**. Strongly connected components: **1**.

- `authorization_kernel`, `calls`, `conversations`, `identity_access`, `tenant_administration`

### Runtime graph

Declared runtime control flow (consumer -> provider).

| Source | Targets |
|---|---|
| `identity_access` | `conversations`, `notification_delivery` |
| `tenant_administration` | `identity_access` |

Edges: **3**. Strongly connected components: **0**.

### Combined graph

Union of compiled references and runtime control flow.

| Source | Targets |
|---|---|
| `authorization_kernel` | `conversations`, `identity_access`, `tenant_administration` |
| `calls` | `audit`, `authorization_kernel`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversation_content` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversations` | `audit`, `calls`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `identity_access` | `audit`, `calls`, `conversations`, `notification_delivery`, `tenant_administration` |
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `tenant_administration` | `audit`, `calls`, `identity_access` |
| `trust_governance` | `audit`, `calls`, `conversation_content`, `conversations`, `identity_access`, `tenant_administration` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **48**. Strongly connected components: **1**.

- `authorization_kernel`, `calls`, `conversations`, `identity_access`, `notification_delivery`, `tenant_administration`