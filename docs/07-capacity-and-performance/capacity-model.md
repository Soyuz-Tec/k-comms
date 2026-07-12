# Capacity Model

**Status:** Formula draft; replace assumptions with measured benchmark inputs.

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
| MAU | TBD | TBD | TBD |
| Peak concurrent fraction | TBD | TBD | TBD |
| Peak messages/sec | TBD | TBD | TBD |
| Average online recipients | TBD | TBD | TBD |
| Maximum channel size | TBD | TBD | TBD |
| Daily attachment volume | TBD | TBD | TBD |

## Required output

- Edge/API replicas and connection budget
- Database write/read IOPS, storage, connections, and replica needs
- PubSub fan-out and network budget
- Worker queue concurrency by queue
- Object-storage and CDN throughput
- Search-index ingest and query capacity
- Observability ingest and retention cost

Do not convert theoretical BEAM process limits directly into production capacity. Use safe thresholds from representative soak tests with realistic payloads and failure injection.
