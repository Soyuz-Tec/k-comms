# Availability and Resilience

## Failure containment

- Multiple application instances across failure zones.
- No dependence on node-local durable state.
- Supervision boundaries isolate endpoint, worker, and integration failures.
- Timeouts and circuit breakers bound dependency failure propagation.
- Queues have concurrency limits and separate criticality classes.
- Large tenants and channels have quotas and isolation controls.

## Graceful degradation order

1. Preserve message acceptance and history reads.
2. Degrade presence and typing.
3. Delay search indexing and analytics.
4. Delay non-critical notifications and integrations.
5. Restrict attachment processing by size or type if necessary.

The exact order requires product approval and should be encoded in feature flags and runbooks.
