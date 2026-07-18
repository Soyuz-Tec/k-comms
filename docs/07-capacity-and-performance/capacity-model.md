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
| `c_media` | Peak concurrent call participants by media kind and group-size distribution |
| `b_media` | Measured SFU ingress/egress and TURN-relay bitrate per participant profile |
| `h` | Headroom multiplier |

## Core formulas

```text
peak_connections = MAU × f_concurrent × d_user × h
live_deliveries_per_second = mps × r_online × h
message_storage_per_day = messages_per_day × s_message × replication_and_index_factor
edge_nodes = ceil(peak_connections / tested_safe_connections_per_node) + failure_reserve
worker_concurrency = peak_job_arrival_rate × target_processing_time × h
media_egress = sum(concurrent_subscriptions × measured_adaptive_track_bitrate) × h
turn_capacity = forced_relay_participants × measured_relay_bitrate × h
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
| Concurrent audio/video participants and group-size distribution | External forecast | External forecast | Approved direct/group stress scenario |
| Camera/screen profiles and forced-TURN fraction | Measured approved profile | Measured approved profile | Approved degraded-network scenario |

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
- LiveKit room/participant, SFU CPU/network, regional egress, and TURN/TLS relay
  capacity for direct and representative group video plus screen sharing

Do not convert theoretical BEAM process limits directly into production capacity. Use safe thresholds from representative soak tests with realistic payloads and failure injection.

The local loopback Compose call proof establishes functional signaling and
same-host media only. It cannot establish internet bandwidth, NAT traversal,
TURN/TLS throughput, browser/device decode limits, or a safe maximum group size.
Each production environment must approve those limits from representative
audio/video/screen profiles at expected peak plus failure headroom; this release
does not invent a portable hard application participant cap.
