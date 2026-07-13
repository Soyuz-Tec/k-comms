# Architecture Decision Records

ADRs capture decisions that materially constrain implementation or operation.

| ADR | Decision | Status |
|---|---|---|
| 0001 | Start as a modular monolith | Proposed |
| 0002 | Use PostgreSQL as the authoritative store | Proposed |
| 0003 | Use Phoenix Channels, PubSub, and Presence | Proposed |
| 0004 | Persist jobs/outbox records transactionally | Proposed |
| 0005 | Store attachments in object storage | Proposed |
| 0006 | Use server-readable encrypted messages for the first release | Accepted for MVP |
| 0007 | Use React and TypeScript for the reference web client | Accepted for MVP |
| 0008 | Use Podman locally and Kubernetes-neutral deployment contracts | Accepted for MVP |
| 0009 | Defer voice and video to a separate media-plane phase | Accepted for MVP |
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

Create a new ADR rather than rewriting the historical rationale of an approved decision. Supersede older ADRs explicitly.
