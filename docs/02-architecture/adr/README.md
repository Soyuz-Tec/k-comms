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
| 0026 | Enforce business-context boundaries inside comms_core | Accepted |
| 0027 | Keep messages and attachments in one conversation-content boundary | Accepted |
| 0028 | Consolidate notification delivery behind one facade | Accepted |
| 0029 | Coordinate legal-hold-aware message deletion in Governance | Accepted |
| 0030 | Use one-way owner contracts for Governance coordination | Accepted |
| 0031 | Own service-message workflows in ConversationContent | Accepted |
| 0032 | Invert the identity-notification lifecycle dependency | Accepted |
| 0033 | Own conversation admission and compose quota usage | Accepted |
| 0034 | Invert identity-to-conversation workflows | Accepted |

Create a new ADR rather than rewriting the historical rationale of an approved decision. Supersede older ADRs explicitly.
