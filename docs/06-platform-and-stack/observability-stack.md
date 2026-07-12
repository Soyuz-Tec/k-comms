# Observability Stack

## Signals

- Distributed traces for request, command, database, job, and provider paths.
- Metrics for service-level indicators, saturation, queues, and runtime health.
- Structured logs for diagnosable events without message content.
- Audit events kept separately from ordinary operational logs.

## Correlation fields

`request_id`, `trace_id`, `tenant_id` where policy permits, `actor_id` where necessary, `conversation_id` as a hashed/opaque field, `message_id`, `job_id`, `deployment_version`, and `region`.

Cardinality budgets must be enforced; raw user-entered text is prohibited in metric labels.
