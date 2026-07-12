# ADR-0001: Start as a modular monolith

- **Status:** Proposed
- **Date:** TBD
- **Owners:** Architecture

## Context

The communication platform requires a design that is durable, operable, and able to evolve without premature distributed-system complexity.

## Decision

Implement one governed Elixir codebase with explicit domain boundaries and separately deployable runtime roles. Extract services only after measured scaling, isolation, ownership, or regulatory need.

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
