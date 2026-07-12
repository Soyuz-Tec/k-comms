# ADR-0005: Store attachments in object storage

- **Status:** Proposed
- **Date:** TBD
- **Owners:** Architecture

## Context

The communication platform requires a design that is durable, operable, and able to evolve without premature distributed-system complexity.

## Decision

Clients upload using short-lived signed URLs. Metadata and authorization remain in PostgreSQL. Files are quarantined until verification and scanning complete.

## Alternatives considered

- Introduce independent services and dedicated infrastructure at initial launch.
- Use in-memory or eventually durable state for the primary path.
- Adopt a different mechanism based on future benchmark evidence.

## Consequences

- The initial system has fewer transactional and operational boundaries.
- Boundaries must be enforced in code and CI rather than assumed from network separation.
- The decision must be validated with representative load and failure testing.

## Revisit triggers

- Approved requirements cannot be met within the current boundary.
- Benchmarks demonstrate a material scaling bottleneck.
- Regulatory, residency, or ownership needs require isolation.
