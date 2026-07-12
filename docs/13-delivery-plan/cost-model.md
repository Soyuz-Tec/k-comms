# Cost Model

## Cost categories

- Engineering and product labor
- Runtime compute for edge, workers, and administrative roles
- PostgreSQL compute, storage, backups, replicas, and I/O
- Object storage, scanning, transformation, and CDN egress
- Search cluster and indexing
- Telemetry ingest and retention
- Push/email/SMS or identity provider fees
- CI/CD, artifact storage, test environments, and security tooling
- Disaster-recovery standby capacity
- Support, on-call, and vendor support contracts

## Unit economics to track

```text
cost per monthly active user
cost per peak concurrent connection
cost per million messages
cost per GB attachment stored and delivered
cost per retained telemetry GB
cost of required recovery posture
```

Model launch, expected-growth, and stress scenarios. Separate fixed platform cost from usage-proportional cost and identify the top three sensitivity variables.
