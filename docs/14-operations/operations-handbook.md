# Operations Handbook

## Operating model

- Named service and domain owners
- Tiered support and escalation
- 24×7 on-call for production-critical capabilities where required
- Incident command, communications, and post-incident review
- Change and maintenance management
- Capacity, cost, security, and access reviews

## Daily/weekly checks

- SLO and burn-rate status
- Database health, replication lag, storage growth
- Queue age and retry/dead-letter volume
- Search lag and reconciliation
- Attachment scan failures
- Provider delivery failures
- Security alerts and privileged-access events
- Cost anomalies and capacity headroom

## Release-bound operating evidence

Before traffic, operations validates the alert, dashboard, and runbook contract:

```bash
python scripts/validate_ops_assets.py
```

The check proves the repository assets are complete and internally linked; it
does not prove that a production scraper, dashboard, receiver, roster, or
operator exists. Target-environment alert delivery, operator exercises, and
authority evidence are retained outside Git and linked from the exact-release
readiness ledger described in
`docs/13-delivery-plan/internal-production-readiness.md`.

The protected `/ops` surface exposes the image's validated full Git revision
and uses it in every runbook link. An unbound development runtime shows no
clickable runbook instead of linking to mutable `main`. Treat missing revision
metadata as a release-evidence failure before applying operational procedures.

Every incident and exercise records environment, release revision, image and
bundle identity, commands/actions, stop conditions, results, and evidence URI.
Do not store credentials, user content, signed URLs, or participant personal
data in the ledger or ordinary incident record.
