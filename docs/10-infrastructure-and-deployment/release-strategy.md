# Release and Migration Strategy

## Release properties

- Rolling or blue/green deployment.
- Connection draining with reconnect jitter.
- Backward-compatible APIs, events, and database schemas.
- Feature flags separate deployment from activation.
- At least one-release rollback compatibility.

## Expand-and-contract sequence

1. Add new schema or optional fields.
2. Deploy code that reads old and new forms.
3. Begin writing the new form.
4. Backfill and reconcile.
5. Switch reads to the new form.
6. Remove old writes.
7. Remove old schema in a later release.

## Release gate

No production release proceeds without successful staging rehearsal, migration timing evidence, rollback procedure, observability coverage, and named incident ownership.
