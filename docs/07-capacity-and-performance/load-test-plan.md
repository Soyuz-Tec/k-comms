# Load and Soak Test Plan

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
