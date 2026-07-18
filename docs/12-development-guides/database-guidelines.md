# Database Development Guidelines

- Every tenant-owned query begins from explicit tenant context.
- Use constraints as the final defense for uniqueness and idempotency.
- Keep transactions short and free of external network calls.
- Analyze query plans for high-volume paths.
- Batch backfills and retention work.
- Set explicit statement and lock timeout behavior for operational jobs.
- Never assume application validation replaces database integrity.
- Add indexes with measured query evidence and monitor write amplification.
- Treat `DATABASE_SSL=true` as authenticated TLS: require a reviewed mounted
  CA bundle, explicit certificate DNS name, peer verification, SNI, and
  hostname verification. Never replace this with `verify_none`.
- Rehearse managed PostgreSQL CA rotation with an overlap bundle and verify
  edge, worker, migration, and operational release commands reconnect before
  retiring the old CA.
