# Context-boundary violation baseline

Generated from `scripts/validate_architecture.py --write-boundary-baseline`.
Existing fingerprints are migration debt. Relative to the checked-in baseline,
new, changed, or resolved fingerprints fail CI; baseline edits require architecture review.

Total tracked violations: **46**.

## adapter_schema_import (1)

| Fingerprint | Location | Evidence |
|---|---|---|
| `7a1ffc82ac877370` | `apps/comms_web/lib/comms_web/presenter.ex` | adapter references internal Ecto schema CommsCore.AudioCalls.AudioCall |

## business_context_cycle (1)

| Fingerprint | Location | Evidence |
|---|---|---|
| `a26844eb317ed35d` | `docs/02-architecture/context-boundaries.yaml` | members: authorization_kernel, calls, conversations, identity_access, tenant_administration; edges: authorization_kernel->conversations, authorization_kernel->identity_access, authorization_kernel->tenant_administration, calls->authorization_kernel, calls->conversations, calls->identity_access, calls->tenant_administration, conversations->calls, conversations->identity_access, conversations->tenant_administration, identity_access->calls, identity_access->tenant_administration, tenant_administration->calls |

## foreign_schema_import (30)

| Fingerprint | Location | Evidence |
|---|---|---|
| `46833d9e4f37a9f4` | `apps/comms_core/lib/comms_core/accounts.ex` | CommsCore.Accounts references owner-internal schema CommsCore.Accounts.Tenant |
| `2a53bebf9a2c2b68` | `apps/comms_core/lib/comms_core/accounts/device.ex` | CommsCore.Accounts.Device references owner-internal schema CommsCore.Accounts.Tenant |
| `42cd72ee581f329d` | `apps/comms_core/lib/comms_core/accounts/password_recovery_request.ex` | CommsCore.Accounts.PasswordRecoveryRequest references owner-internal schema CommsCore.Accounts.Tenant |
| `24d261bf4611f799` | `apps/comms_core/lib/comms_core/accounts/platform_role_grant.ex` | CommsCore.Accounts.PlatformRoleGrant references owner-internal schema CommsCore.Accounts.Tenant |
| `2239525a78f246a4` | `apps/comms_core/lib/comms_core/accounts/session.ex` | CommsCore.Accounts.Session references owner-internal schema CommsCore.Accounts.Tenant |
| `9c00206437b708a1` | `apps/comms_core/lib/comms_core/accounts/socket_ticket.ex` | CommsCore.Accounts.SocketTicket references owner-internal schema CommsCore.Accounts.Tenant |
| `6e01f546438ba1e0` | `apps/comms_core/lib/comms_core/accounts/user.ex` | CommsCore.Accounts.User references owner-internal schema CommsCore.Accounts.Tenant |
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
| `c06055a43f05a1f7` | `apps/comms_core/lib/comms_core/integrations/webhook_delivery.ex` | CommsCore.Integrations.WebhookDelivery references owner-internal schema CommsCore.Events.OutboxEvent |
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

## undeclared_context_edge (8)

| Fingerprint | Location | Evidence |
|---|---|---|
| `889ca078f04b8132` | `apps/comms_core/lib/comms_core/accounts.ex` | identity_access -> calls through CommsCore.AudioCalls |
| `0e985916a4de06ec` | `apps/comms_core/lib/comms_core/administration.ex` | tenant_administration -> calls through CommsCore.AudioCalls |
| `0189e4bac08f3c6e` | `apps/comms_core/lib/comms_core/audio_calls.ex` | calls -> authorization_kernel through CommsCore.Authorization |
| `4f52bd7c42b47a5d` | `apps/comms_core/lib/comms_core/authorization/database.ex` | authorization_kernel -> conversations through CommsCore.Conversations, CommsCore.Conversations.Conversation, CommsCore.Conversations.Membership |
| `47659f71148ad7cd` | `apps/comms_core/lib/comms_core/authorization/database.ex` | authorization_kernel -> identity_access through CommsCore.Accounts, CommsCore.Accounts.Device, CommsCore.Accounts.Session, CommsCore.Accounts.User |
| `22d29c8a33ec3581` | `apps/comms_core/lib/comms_core/authorization/database.ex` | authorization_kernel -> tenant_administration through CommsCore.Accounts.Tenant, CommsCore.Administration.TenantSettings |
| `bec8b11dfcf061c7` | `apps/comms_core/lib/comms_core/conversations.ex` | conversations -> calls through CommsCore.AudioCalls |
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
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `tenant_administration` | `audit`, `calls` |
| `trust_governance` | `audit`, `calls`, `conversation_content`, `conversations`, `identity_access`, `tenant_administration` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **44**. Strongly connected components: **1**.

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
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `tenant_administration` | `audit`, `calls`, `identity_access` |
| `trust_governance` | `audit`, `calls`, `conversation_content`, `conversations`, `identity_access`, `tenant_administration` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **47**. Strongly connected components: **1**.

- `authorization_kernel`, `calls`, `conversations`, `identity_access`, `notification_delivery`, `tenant_administration`