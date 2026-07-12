# Capacity Model

**Status:** Implemented formula and executable local regression profile;
production demand inputs remain an explicit environment-owner launch gate.

## Local qualification input

The versioned local profile runs 300 canonical messages over 60 seconds with a
maximum concurrency of 6, ten idempotency replays, a 750 ms p95 regression
threshold, and zero acknowledged-message loss. The runner records p50, p95,
p99, error rate, achieved throughput, ordered-history reconciliation, and
cleanup outcome. Store the aggregate `RESULT` line with the commit, image
digest, topology, host resources, and timestamp using
[`local-staging-qualification.md`](local-staging-qualification.md).

This profile validates repeatability and detects regressions in the local
Podman staging candidate. It does not establish per-node safe capacity,
multi-node fan-out limits, failure headroom, or production SLO compliance.

## Primary variables

| Symbol | Meaning |
|---|---|
| `MAU` | Monthly active users |
| `f_concurrent` | Peak concurrently connected fraction |
| `d_user` | Average connected devices per active user |
| `mps` | Peak accepted messages per second |
| `r_online` | Average online recipients per message |
| `s_message` | Average stored bytes per message including indexes/metadata |
| `a_day` | Attachment bytes uploaded per day |
| `h` | Headroom multiplier |

## Core formulas

```text
peak_connections = MAU × f_concurrent × d_user × h
live_deliveries_per_second = mps × r_online × h
message_storage_per_day = messages_per_day × s_message × replication_and_index_factor
edge_nodes = ceil(peak_connections / tested_safe_connections_per_node) + failure_reserve
worker_concurrency = peak_job_arrival_rate × target_processing_time × h
```

## Scenario table

| Input | Launch | Growth | Stress |
|---|---:|---:|---:|
| MAU | External forecast | External forecast | Approved stress scenario |
| Peak concurrent fraction | Measured launch forecast | Measured growth forecast | Approved stress scenario |
| Peak messages/sec | Measured launch forecast | Measured growth forecast | Approved stress scenario |
| Average online recipients | Measured launch forecast | Measured growth forecast | Approved stress scenario |
| Maximum channel size | Tenant limit, default 250 | Approved growth limit | Maximum tested limit |
| Daily attachment volume | External forecast | External forecast | Approved stress scenario |

Do not populate this launch/growth/stress table from the local qualification
run. Those inputs require an approved workload forecast and representative
multi-node tests.

## Required output

- Edge/API replicas and connection budget
- Database write/read IOPS, storage, connections, and replica needs
- PubSub fan-out and network budget
- Worker queue concurrency by queue
- Object-storage and CDN throughput
- Search-index ingest and query capacity
- Observability ingest and retention cost

Do not convert theoretical BEAM process limits directly into production capacity. Use safe thresholds from representative soak tests with realistic payloads and failure injection.
