# Load and Soak Test Plan

## Executable local staging profile

`node scripts/staging_load.mjs` is the dependency-free message-acceptance
qualifier for the local Podman staging candidate and a deployed staging origin.
It always creates its own private conversation, sends a bounded workload,
replays selected `Idempotency-Key` values, reconciles every acknowledged
message through ordered paginated history, then archives the conversation and
revokes its run-scoped device (or logs out as a fallback). It never selects or
deletes an existing conversation.

The conservative default is 30 canonical messages, concurrency 3, spread over
10 seconds, with three duplicate probes. The proposed repeatable local
qualification profile is:

| Input or gate | Proposed local value |
|---|---:|
| Canonical messages | 300 |
| Maximum in-flight sends | 6 |
| Send window | 60 seconds |
| Idempotency duplicate probes | 10 |
| Per-request timeout | 15 seconds |
| Message-acceptance p95 gate | 750 ms |
| Acknowledged-message loss gate | 0 |

This is a regression and packaging gate for one local staging topology. It is
not production sizing evidence and does not prove the proposed production SLO.
Run and evidence-capture instructions are in
[`local-staging-qualification.md`](local-staging-qualification.md).

## Test layers

- Component benchmark for sequence allocation and message transaction.
- Single-node WebSocket connection and fan-out benchmark.
- Multi-node PubSub benchmark.
- Full-stack message, sync, notification, and search workload.
- Long-duration soak with node recycling and database maintenance.
- Reconnect-storm and provider-failure tests.

## Exit criteria

- SLO targets met at expected peak plus approved headroom.
- No unbounded mailbox, memory, queue, or connection growth.
- Recovery after overload without manual data repair.
- Database lock and replication lag remain within budgets.
- Autoscaling does not oscillate or amplify reconnect traffic.
- Results are reproducible from versioned test configuration.
- Every acknowledged run-scoped message is present exactly once in ascending
  canonical history and duplicate probes return the original ID and sequence.
- Run-scoped resources are archived/revoked without deleting existing data.
