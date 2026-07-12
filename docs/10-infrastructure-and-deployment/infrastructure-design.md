# Infrastructure Design

**Status:** Draft

## Baseline topology

- One primary cloud region across at least two availability zones.
- Public CDN/WAF/load balancer terminating external traffic.
- Private application network for edge/API and worker runtimes.
- Managed PostgreSQL primary plus standby.
- Object storage and CDN for attachments.
- Central telemetry collection and managed secret/key services.
- Warm disaster-recovery capability in a second region.

## Infrastructure principles

- All environments are created from versioned code.
- Application nodes are replaceable and hold no unique durable state.
- Network access follows least privilege.
- Administrative access is audited and time-bounded.
- Resources have ownership, environment, data-classification, and cost tags.
- Backups, restore paths, and key dependencies are part of the design.
