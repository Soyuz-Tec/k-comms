# Observability Guide

New critical paths require:

- Trace spans around application commands, database operations, and external calls.
- Metrics for success, failure, latency, saturation, and queue age.
- Structured logs for exceptional diagnosis.
- Correlation IDs propagated across jobs and webhooks.
- Dashboards and alert/runbook linkage for SLO-affecting behavior.

Do not emit user-entered message content, access tokens, secrets, or high-cardinality metric labels.
