# ADR-0001: Start as a modular monolith

- **Status:** Accepted
- **Date:** 2026-07-12
- **Owners:** Architecture and engineering

## Context

The communication platform requires a design that is durable, operable, and able to evolve without premature distributed-system complexity.

## Decision

Implement one governed Elixir umbrella and one release artifact with explicit
domain boundaries. Edge and worker deployments select separately scalable
runtime roles from that same artifact; they are not independent services.

`comms_core` owns domain rules, application commands, and authoritative
persistence. Web, worker, and provider adapters depend inward on explicit core
APIs or core-owned ports. Core must not name, start, or otherwise reference
adapter applications, including through module-name strings or OTP application
atoms. Root configuration and release assembly are the composition root where
core-owned ports may be bound to concrete adapter implementations.

The accepted dependency matrix and narrow persistence exceptions are maintained
in the [architecture overview](../architecture-overview.md#application-module-boundaries)
and enforced by `scripts/validate_architecture.py`. Extract a service only after
measured scaling, isolation, ownership, residency, or regulatory need exceeds
the operational cost of a distributed boundary.

## Alternatives considered

- Introduce independent services and dedicated infrastructure at initial launch.
- Use in-memory or eventually durable state for the primary path.
- Adopt a different mechanism based on future benchmark evidence.

## Consequences

- The initial system has fewer transactional and operational boundaries.
- Boundaries must be enforced in code and CI rather than assumed from network separation.
- The decision must be validated with representative load and failure testing.
- A new umbrella application, dependency edge, or direct persistence exception
  requires architecture review and a policy update in the same change.

## Validation

- CI rejects unclassified umbrella applications and forbidden in-umbrella
  dependency edges.
- CI rejects any runtime `comms_core` reference to web, worker, integration, or
  observability adapters, including textual module names and OTP app atoms.
- CI rejects direct `CommsCore.Repo` access outside core except for the exact
  non-release test fixture helper documented in the architecture overview;
  operational adapters use narrowly named core read APIs.
- Umbrella tests, exact-image smoke tests, and staging acceptance validate that
  stronger boundaries preserve product behavior.

## Revisit triggers

- Approved requirements cannot be met within the current boundary.
- Benchmarks demonstrate a material scaling bottleneck.
- Regulatory, residency, or ownership needs require isolation.
