# ADR-0006: Server-readable encrypted message baseline

- **Status:** Accepted for MVP
- **Date:** 2026-07-12
- **Owners:** Architecture and product

## Context

The MVP needs history, moderation, search, notifications, and simple multi-device recovery. True end-to-end encryption would change every one of those protocols and requires dedicated client key management.

## Decision

Messages remain readable by authorized server components. TLS protects data in transit; PostgreSQL, object storage, and backups require encryption at rest. Application logs and traces exclude message bodies. E2EE is deferred behind a separate protocol ADR.

## Consequences

The MVP can provide server-side search and moderation. Production access controls, audit evidence, key rotation, and support-access policy remain mandatory. A later E2EE mode is not a transparent toggle.
