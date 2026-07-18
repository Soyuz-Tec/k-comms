# Performance and Soak Testing

Run representative payloads, TLS, authentication, database indexes, telemetry, and background work. Track scheduler utilization, run queues, process/mailbox growth, heap/memory, garbage collection, database waits, replication lag, and network throughput.

A soak test should include rolling restarts, routine maintenance, intermittent provider failure, and realistic client reconnect behavior.

For safe single-topology staging qualification, use
`node scripts/staging_load.mjs`. It provides bounded count/concurrency/duration,
duplicate-command probes, ordered paginated-history reconciliation, aggregate
latency/error output, explicit p95 and zero-loss gates, and run-scoped cleanup.
The 15-minute local soak example in
[`local-staging-qualification.md`](../07-capacity-and-performance/local-staging-qualification.md)
is a stability screen only. Rolling restart, reconnect storm, multi-node fan-out,
database maintenance, and provider failure remain separate production-readiness
exercises.
