# ADR-0003: Use Phoenix Channels, PubSub, and Presence

- **Status:** Proposed
- **Date:** TBD
- **Owners:** Architecture

## Context

The communication platform requires a design that is durable, operable, and able to evolve without premature distributed-system complexity.

## Decision

Use Phoenix Channels for WebSocket sessions, PubSub for cluster fan-out, and Presence for ephemeral online state. Durable replay remains an application protocol responsibility.

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
