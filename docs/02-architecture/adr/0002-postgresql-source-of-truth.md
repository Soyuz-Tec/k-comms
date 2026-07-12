# ADR-0002: Use PostgreSQL as the authoritative store

- **Status:** Proposed
- **Date:** TBD
- **Owners:** Architecture

## Context

The communication platform requires a design that is durable, operable, and able to evolve without premature distributed-system complexity.

## Decision

Persist accepted messages, memberships, policies, audit records, and durable work requests in PostgreSQL transactions. Search and caches remain rebuildable projections.

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
