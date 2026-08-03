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
| `calls` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `collaboration` | `conversations` |
| `conversation_content` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversations` | `audit`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `identity_access` | `audit`, `tenant_administration` |
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `tenant_administration` | `audit` |
| `trust_governance` | `audit`, `calls`, `collaboration`, `conversation_content`, `conversations`, `identity_access`, `tenant_administration` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **39**. Strongly connected components: **0**.

### Runtime graph

Declared runtime control flow (consumer -> provider).

| Source | Targets |
|---|---|
| `conversations` | `calls`, `collaboration` |
| `identity_access` | `calls`, `conversations`, `notification_delivery` |
| `tenant_administration` | `calls`, `identity_access` |

Edges: **7**. Strongly connected components: **0**.

### Combined graph

Union of compiled references and runtime control flow.

| Source | Targets |
|---|---|
| `calls` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `collaboration` | `conversations` |
| `conversation_content` | `audit`, `conversations`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `conversations` | `audit`, `calls`, `collaboration`, `identity_access`, `platform_eventing`, `tenant_administration` |
| `identity_access` | `audit`, `calls`, `conversations`, `notification_delivery`, `tenant_administration` |
| `notification_delivery` | `audit`, `conversations`, `identity_access`, `platform_eventing` |
| `operations_read_model` | `conversation_content`, `conversations`, `identity_access`, `notification_delivery`, `platform_eventing`, `tenant_administration`, `webhook_management` |
| `tenant_administration` | `audit`, `calls`, `identity_access` |
| `trust_governance` | `audit`, `calls`, `collaboration`, `conversation_content`, `conversations`, `identity_access`, `tenant_administration` |
| `webhook_management` | `audit`, `identity_access`, `platform_eventing` |

Edges: **46**. Strongly connected components: **1**.

- `calls`, `collaboration`, `conversations`, `identity_access`, `notification_delivery`, `tenant_administration`