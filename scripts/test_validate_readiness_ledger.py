#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import unittest
from datetime import datetime, timezone
from pathlib import Path

from jsonschema import Draft202012Validator

from validate_readiness_ledger import validate_document


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = (
    ROOT
    / "docs"
    / "13-delivery-plan"
    / "internal-production-readiness-ledger.schema.json"
)
TEMPLATE_PATH = (
    ROOT
    / "docs"
    / "13-delivery-plan"
    / "internal-production-readiness-ledger.template.json"
)
AS_OF = datetime(2026, 7, 15, 12, 0, 0, tzinfo=timezone.utc)


class ReadinessLedgerValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.template = json.loads(TEMPLATE_PATH.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(cls.schema)

    def test_pending_template_is_valid_but_not_production_ready(self) -> None:
        self.assertEqual(validate_document(self.template, self.schema, as_of=AS_OF), [])
        self.assertTrue(self.template["template"])
        self.assertFalse(self.template["production_ready"])
        self.assertEqual(self.template["decision"]["status"], "pending")

    def test_complete_approved_ledger_is_valid(self) -> None:
        document = self.approved_ledger()
        self.assertEqual(validate_document(document, self.schema, as_of=AS_OF), [])

    def test_missing_gate_is_rejected(self) -> None:
        document = self.approved_ledger()
        document["gates"].pop()
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(any("missing required gate ids" in error for error in errors))

    def test_approval_cannot_hide_pending_gate(self) -> None:
        document = self.approved_ledger()
        document["gates"][0]["status"] = "pending"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(
            any("requires every gate to be passed" in error for error in errors)
        )

    def test_expired_pass_must_be_rerun(self) -> None:
        document = self.approved_ledger()
        document["gates"][0]["review_due_at"] = "2026-07-15T11:59:59Z"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(any("is expired as of" in error for error in errors))

    def test_passed_gate_requires_separate_normalized_approver(self) -> None:
        document = self.approved_ledger()
        document["gates"][0]["owner"] = "Application Owner"
        document["gates"][0]["approver"] = "application   owner"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(
            any("approver must be separate from the gate owner" in error for error in errors)
        )

    def test_approval_cannot_predate_a_passed_gate_assessment(self) -> None:
        document = self.approved_ledger()
        document["gates"][0]["assessed_at"] = "2026-07-15T11:31:00Z"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(
            any(
                "decision.decided_at must be at or after gates[0]" in error
                and ".assessed_at" in error
                for error in errors
            )
        )

    def test_approval_cannot_predate_a_passed_signoff(self) -> None:
        document = self.approved_ledger()
        document["signoffs"][0]["signed_at"] = "2026-07-15T11:31:00Z"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(
            any(
                "decision.decided_at must be at or after signoffs[0]" in error
                and ".signed_at" in error
                for error in errors
            )
        )

    def test_ledger_generation_cannot_predate_approval(self) -> None:
        document = self.approved_ledger()
        document["generated_at"] = "2026-07-15T11:29:59Z"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertIn("generated_at must be at or after decision.decided_at", errors)

    def test_evidence_uri_rejects_query_credentials(self) -> None:
        document = self.approved_ledger()
        document["gates"][0]["evidence_uri"] = (
            "https://evidence.example.test/release?token=do-not-store"
        )
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(any("must not contain embedded credentials" in error for error in errors))

    def test_template_cannot_claim_a_pass(self) -> None:
        document = copy.deepcopy(self.template)
        document["gates"][0]["status"] = "passed"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(any("every template gate must remain pending" in error for error in errors))

    def test_release_signoff_requires_all_roles(self) -> None:
        document = self.approved_ledger()
        document["signoffs"][0]["status"] = "pending"
        errors = validate_document(document, self.schema, as_of=AS_OF)
        self.assertTrue(any("cannot pass before every required signoff" in error for error in errors))

    def approved_ledger(self) -> dict:
        document = copy.deepcopy(self.template)
        document["template"] = False
        document["generated_at"] = "2026-07-15T11:30:00Z"
        document["release"] = {
            "git_revision": "a" * 40,
            "image_digest": f"sha256:{'b' * 64}",
            "bundle_sha256": "c" * 64,
            "environment_id": "internal-production/us-east-1",
        }
        document["production_ready"] = True
        document["decision"] = {
            "status": "approved",
            "decided_at": "2026-07-15T11:30:00Z",
            "expires_at": "2026-08-01T00:00:00Z",
            "approver": "release-authority",
            "evidence_uri": "evidence://release/decision",
            "notes": "Fixture approval backed by synthetic test evidence only.",
        }
        for gate in document["gates"]:
            gate["status"] = "passed"
            gate["owner"] = f"owner-{gate['category']}"
            gate["approver"] = f"approver-{gate['category']}"
            gate["assessed_at"] = "2026-07-15T10:00:00Z"
            gate["review_due_at"] = "2026-08-01T00:00:00Z"
            gate["evidence_uri"] = f"evidence://release/{gate['id'].replace('.', '/')}"
        for signoff in document["signoffs"]:
            signoff["status"] = "passed"
            signoff["signer"] = f"{signoff['role']}-authority"
            signoff["signed_at"] = "2026-07-15T11:00:00Z"
            signoff["evidence_uri"] = f"evidence://release/signoff/{signoff['role']}"
        return document


if __name__ == "__main__":
    unittest.main()
