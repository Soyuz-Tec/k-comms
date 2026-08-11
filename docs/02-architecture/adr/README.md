# Architecture Decision Records

ADRs capture decisions that materially constrain implementation or operation.

| ADR | Decision | Status |
|---|---|---|
| 0001 | Start as a modular monolith | Accepted |
| 0002 | Use PostgreSQL as the authoritative store | Proposed |
| 0003 | Use Phoenix Channels, PubSub, and Presence | Proposed |
| 0004 | Persist jobs/outbox records transactionally | Proposed |
| 0005 | Store attachments in object storage | Proposed |
| 0006 | Use server-readable encrypted messages for the first release | Accepted for MVP |
| 0007 | Use React and TypeScript for the reference web client | Accepted for MVP |
| 0008 | Use Podman locally and Kubernetes-neutral deployment contracts | Accepted for MVP |
| 0009 | Defer voice and video to a separate media-plane phase | Superseded for audio/video by ADR-0024 and ADR-0025 |
| 0010 | Separate user, tenant-admin, and platform-operations product surfaces | Accepted |
| 0011 | Persist external delivery state and fail closed for unsafe attachments | Accepted |
| 0012 | Use managed production stateful services and restricted operations access | Accepted |
| 0013 | Separate service-account authentication from human sessions | Accepted |
| 0014 | Keep VAPID private keys at the provider and encrypt browser subscriptions | Accepted |
| 0015 | Use explicit mentions, canonical threads, and durable in-app notification state | Accepted |
| 0016 | Bound and neutralize audit CSV exports | Accepted |
| 0017 | Enforce tenant admission quotas in PostgreSQL transactions | Accepted |
| 0018 | Harden recovery identity, invitation, and session boundaries | Accepted |
| 0019 | Enforce content, delivery, and resource boundaries | Accepted |
| 0020 | Require expiring platform-role grants | Accepted |
| 0021 | Authenticate managed PostgreSQL TLS | Accepted |
| 0022 | Publish digest-bound keyless provenance and SBOM attestations | Accepted |
| 0023 | Define the corporate OIDC and SCIM identity boundary | Proposed |
| 0024 | Add audio-only calls through a LiveKit media plane | Superseded for active implementation by ADR-0025 |
| 0025 | Unify audio and video calls on the LiveKit media plane | Accepted for implementation and internal pilot |
| 0026 | Enforce business-context boundaries inside comms_core | Accepted; enforcement mechanics superseded by ADR-0035 |
| 0027 | Keep messages and attachments in one conversation-content boundary | Accepted |
| 0028 | Consolidate notification delivery behind one facade | Accepted |
| 0029 | Coordinate legal-hold-aware message deletion in Governance | Accepted |
| 0030 | Use one-way owner contracts for Governance coordination | Accepted |
| 0031 | Own service-message workflows in ConversationContent | Accepted |
| 0032 | Invert the identity-notification lifecycle dependency | Accepted |
| 0033 | Own conversation admission and compose quota usage | Accepted |
| 0034 | Invert identity-to-conversation workflows | Accepted |
| 0035 | Complete the modular-monolith boundary control plane | Accepted |
| 0036 | Invert TenantAdministration identity workflows | Accepted |
| 0037 | Contain NotificationDelivery persistence | Accepted |
| 0038 | Contain Conversations persistence | Accepted |
| 0039 | Contain TrustGovernance persistence | Accepted |
| 0040 | Contain ConversationContent persistence | Accepted |
| 0041 | Assign tenants to TenantAdministration | Accepted |
| 0042 | Complete non-audio modularization and activate the strict gate | Accepted |
| 0043 | Complete the Calls boundary and retire the authorization kernel | Accepted |
| 0044 | Retrospectively accept the full PR #16 endgame scope | Accepted |
| 0045 | Harden zero-baseline architecture assurance | Accepted |
| 0046 | Add owner-projected mobile member read contracts | Accepted |
| 0047 | Qualify an immutable loopback-only local release | Accepted |
| 0048 | Make abandoned upload cleanup durable and convergent | Accepted |
| 0049 | Add conversation guest links and convertible guest identities | Accepted |
| 0050 | Add self-service instant rooms | Accepted for implementation; production enablement gated |
| 0051 | Use a host forwarder for explicit private-LAN release access | Accepted |
| 0052 | Retain message sender labels as an authorized history sidecar | Accepted |
| 0053 | Provision the local-release tenant through a sealed one-shot command | Accepted |
| 0054 | Use a Cloudflare trusted edge for same-LAN browser media | Accepted for controlled same-LAN qualification; not production |
| 0055 | Operate a digest-promoted K-Comms release on dedicated Proxmox VMs | Accepted for the single-site internal production profile |
| 0056 | Harden cryptographic policy enforcement | Accepted |
| 0057 | Use managed LiveKit Cloud for Internet media transport | Accepted |
| 0058 | Automate protected merge-to-production promotion | Accepted |
| 0059 | Treat Windows interface indices as diagnostic local-release evidence | Accepted |
| 0060 | Add an install-scoped progressive web application | Accepted |
| 0061 | Store attachment derived renditions as variants | Accepted |
| 0062 | Preserve public facades while separating cohesive implementation modules | Accepted |
| 0063 | Add conversation whiteboards through a replaceable Excalidraw adapter | Accepted |
| 0064 | Make the protected Proxmox deployment runner portable | Accepted |
| 0065 | Make instant rooms collaboration workspaces | Accepted |
| 0066 | Allow local-first instant workspace drafts | Accepted |
| 0067 | Add durable messaging receipts and authorized call collaboration controls | Accepted |
| 0068 | Reclaim an instant room's whiteboard when the room expires | Accepted |
| 0069 | Materialise whiteboard scenes so joining is not O(history) | Accepted |
| 0070 | Accept whole-element whiteboard merge until the editor engine changes | Accepted |
| 0071 | Add client-side office call readiness qualification | Accepted for implementation |
| 0072 | Add an opt-in direct transport for one-to-one audio | Accepted for implementation |
| 0073 | Harden direct-audio signaling and resource boundaries | Accepted |

Create a new ADR rather than rewriting the historical rationale of an approved decision. Supersede older ADRs explicitly.
