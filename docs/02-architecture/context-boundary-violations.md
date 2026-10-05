# Context-boundary violation baseline

Generated from `scripts/validate_architecture.py --write-boundary-baseline`.
Existing fingerprints are migration debt. Relative to the checked-in baseline,
new, changed, or resolved fingerprints fail CI; baseline edits require architecture review.

Total tracked violations: **0**.

## Context dependency graphs

### Compiled graph

Static production module references (source owner -> referenced owner).

| Source | Targets |
|---|---|
| `calls` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `telephony`, `tenant_administration` |
| `collaboration` | `conversations`, `identity_access` |
| `conversation_content` | `audit`, `collaboration`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversations` | `audit`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `identity_access` | `audit`, `tenant_administration` |
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `telephony` | `audit`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `tenant_administration` | `audit` |
| `trust_governance` | `audit`, `calls`, `collaboration`, `conversation_content`, `conversations`, `identity_access`, `platform_eventing`, `telephony`, `tenant_administration`, `webhook_management` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **49**. Strongly connected components: **0**.

### Runtime graph

Declared runtime control flow (consumer -> provider).

| Source | Targets |
|---|---|
| `calls` | `trust_governance` |
| `collaboration` | `conversation_content` |
| `conversations` | `calls`, `collaboration` |
| `identity_access` | `calls`, `conversations`, `notification_delivery` |
| `telephony` | `trust_governance` |
| `tenant_administration` | `calls`, `identity_access`, `trust_governance` |

Edges: **11**. Strongly connected components: **0**.

### Combined graph

Union of compiled references and runtime control flow.

| Source | Targets |
|---|---|
| `calls` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `telephony`, `tenant_administration`, `trust_governance` |
| `collaboration` | `conversation_content`, `conversations`, `identity_access` |
| `conversation_content` | `audit`, `collaboration`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversations` | `audit`, `calls`, `collaboration`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `identity_access` | `audit`, `calls`, `conversations`, `notification_delivery`, `tenant_administration` |
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `telephony` | `audit`, `identity_access`, `platform_eventing`, `tenant_administration`, `trust_governance` |
| `tenant_administration` | `audit`, `calls`, `identity_access`, `trust_governance` |
| `trust_governance` | `audit`, `calls`, `collaboration`, `conversation_content`, `conversations`, `identity_access`, `platform_eventing`, `telephony`, `tenant_administration`, `webhook_management` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **60**. Strongly connected components: **1**.

- `calls`, `collaboration`, `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `telephony`, `tenant_administration`, `trust_governance`, `webhook_management`