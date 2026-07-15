# Operations assets

Alert rules, dashboards, runtime manifests, and runbook links live here.

Run `python scripts/validate_ops_assets.py` after changing an alert, dashboard,
or runbook. The validator enforces actionable annotations, immutable release and
environment placeholders, working repository links, dashboard structure, and
capability-specific runbook sections. Provider-native rule validation and a
test page through the real alert receiver remain environment gates.
