# Data Migration Strategy

- Prefer additive schema changes before code depends on them.
- Deploy readers tolerant of old and new formats.
- Backfill asynchronously in small, observable batches.
- Switch writes only after compatibility is verified.
- Remove old fields in a later release after all clients and jobs are migrated.
- Provide explicit rollback behavior for every step.

Each migration plan must specify estimated rows, lock behavior, write amplification, pause/resume controls, monitoring, and abort criteria.
