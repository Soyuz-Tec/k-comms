# Monitoring and Alerting

## Page on

- Fast SLO burn for message acceptance or synchronization
- Data integrity or tenant-isolation signal
- Database primary/replication danger
- Queue age threatening user-visible commitments
- Broad authentication failure
- Confirmed regional or zone outage

## Ticket or investigate

- Slow capacity erosion
- Search lag below user-impact threshold
- Non-critical provider degradation
- Cost drift
- Elevated but bounded retry rates
- Tenant admission limits at capacity or over limit; investigate expected
  growth, stale lifecycle state, or an intentionally reduced policy before
  increasing a limit

Alerts link directly to a dashboard, ownership, and runbook and include deployment/version context.

## Repository assets

- `ops/dashboards/service-overview.json` visualizes authentication, durable
  message commit latency, job age/state, outbox backlog, attachment quarantine,
  and BEAM process/memory signals.
- `ops/alerts/k-comms.rules.yml` defines initial latency, queue-age, discarded
  job, outbox, quarantine, and authentication-failure alerts.

The `/metrics` endpoint requires its dedicated scraper bearer token and a
private network path. Dashboard availability is not a substitute for testing
the configured alert receiver, escalation schedule, and runbook links in every
environment.

Tenant administrators see admission usage in `/admin` with distinct
`at_capacity` and `over_limit` states. Exact capacity is not an outage: reads
and lifecycle-removal actions continue while the next create, join, or
reactivation for that dimension is rejected. Persistent over-limit state after
expected archives, leaves, suspensions, or revocations is a reconciliation
signal. Total object-store usage is monitored separately; per-file attachment
limits and request rate limiting are the current storage-admission controls.
