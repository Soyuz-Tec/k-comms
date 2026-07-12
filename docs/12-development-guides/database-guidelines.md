# Database Development Guidelines

- Every tenant-owned query begins from explicit tenant context.
- Use constraints as the final defense for uniqueness and idempotency.
- Keep transactions short and free of external network calls.
- Analyze query plans for high-volume paths.
- Batch backfills and retention work.
- Set explicit statement and lock timeout behavior for operational jobs.
- Never assume application validation replaces database integrity.
- Add indexes with measured query evidence and monitor write amplification.
