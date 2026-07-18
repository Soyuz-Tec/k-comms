#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

import yaml

from validate_ops_assets import (
    ALERT_RULES,
    DASHBOARD,
    ROOT,
    validate_alert_document,
    validate_dashboard_document,
    validate_ops_assets,
    validate_runbook_text,
)


class OperationsAssetValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.alerts = yaml.safe_load((ROOT / ALERT_RULES).read_text(encoding="utf-8"))
        cls.dashboard = json.loads((ROOT / DASHBOARD).read_text(encoding="utf-8"))

    def test_repository_assets_pass(self) -> None:
        self.assertEqual(validate_ops_assets(ROOT), [])

    def test_alert_requires_actionable_annotation_contract(self) -> None:
        document = copy.deepcopy(self.alerts)
        del document["groups"][0]["rules"][0]["annotations"]["safe_mitigation"]
        errors = validate_alert_document(document, ROOT)
        self.assertTrue(any("missing annotations: safe_mitigation" in error for error in errors))

    def test_alert_requires_release_bound_links(self) -> None:
        document = copy.deepcopy(self.alerts)
        annotations = document["groups"][0]["rules"][0]["annotations"]
        annotations["runbook_url"] = (
            "https://github.com/Soyuz-Tec/k-comms/blob/main/"
            "docs/08-reliability/runbooks/service-degradation.md"
        )
        errors = validate_alert_document(document, ROOT)
        self.assertTrue(any("runbook_url must be release-versioned" in error for error in errors))

    def test_dashboard_rejects_duplicate_panel_ids(self) -> None:
        document = copy.deepcopy(self.dashboard)
        document["panels"][1]["id"] = document["panels"][0]["id"]
        errors = validate_dashboard_document(document)
        self.assertTrue(any("duplicate dashboard panel id" in error for error in errors))

    def test_runbook_requires_explicit_stop_conditions(self) -> None:
        text = "\n".join(
            line
            for line in (ROOT / "docs/08-reliability/runbooks/queue-backlog.md")
            .read_text(encoding="utf-8")
            .splitlines()
            if line != "## Stop conditions"
        )
        errors = validate_runbook_text("queue-backlog.md", text)
        self.assertTrue(any("missing section ## Stop conditions" in error for error in errors))

    def test_generic_skeleton_is_rejected(self) -> None:
        text = """# Runbook: Generic

- **Owner:** Team
- **Alerts/triggers:** Alert
- **Default severity:** Sev-2
- **Dashboard:** dashboard
- **Required context:** release revision

## User impact
## Preconditions and safety warnings
## Initial diagnosis
```bash
true
```
## Stabilization actions
Apply the documented safe degradation control.
## Stop conditions
Stop.
## Escalation
Escalate.
## Recovery validation
Validate.
## Rollback and removal of temporary controls
Rollback.
## Evidence to capture
Capture.
## Follow-up
Follow up.
"""
        errors = validate_runbook_text("generic.md", text)
        self.assertTrue(any("generic placeholder procedure" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
