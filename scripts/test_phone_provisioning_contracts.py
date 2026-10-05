#!/usr/bin/env python3
"""Bounded, credential-free regressions for Phone API/release source contracts."""
from __future__ import annotations

import copy
import json
import re
import unittest
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator, FormatChecker

from validate_phone_provisioning_contracts import (
    ROOT, OPERATIONS, PREFIX, component_refs, validate_phone_provisioning_contract,
)
from validate_production_bundle import (
    COMMUNICATION_ROLLBACK_CAPABILITIES,
    COMMUNICATION_ROLLBACK_CAPABILITY_HAZARDS,
    validate_guest_rollback_preflight, validate_phone_provisioning_production_gate,
)
from validate_proxmox_bundle import ROLLBACK_CAPABILITIES as PROXMOX_CAPABILITIES

MEMBER14 = (
    "guest_identity_v1,guest_admission_expiry_worker_v1,instant_room_lifecycle_v1,"
    "instant_room_presence_lease_v1,instant_room_expiry_worker_v1,conversation_only_human_v1,"
    "enterprise_identity_v1,uc_artifact_lifecycle_v1,uc_voicemail_lifecycle_v1,"
    "uc_advanced_telephony_v1,scheduled_meeting_lifecycle_v1,rich_content_erasure_v1,"
    "member_workspace_v1,governance_history_v1"
)
PHONE_CAPABILITY = "phone_provider_provisioning_v1"
CURRENT = MEMBER14 + "," + PHONE_CAPABILITY
UUID = "11111111-1111-4111-8111-111111111111"


class PhoneProvisioningContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.openapi = yaml.safe_load((ROOT / "contracts/openapi/openapi.yaml").read_text())
        cls.schema = json.loads((ROOT / "contracts/json-schema/phone-provider-provisioning.v1.json").read_text())

    def validator(self, name):
        schema = {"$schema": self.schema["$schema"], "$ref": "#/$defs/" + name,
                  "$defs": self.schema["$defs"]}
        return Draft202012Validator(schema, format_checker=FormatChecker())

    def assignment(self):
        return {"user_id": UUID, "phone_number": "+14155550123", "extension": "101",
                "inbound_trunk_id": "ST_in", "outbound_trunk_id": "ST_out"}

    def receipt(self):
        return {"id": UUID, "request_id": UUID, "status": "unknown", "version": 2,
                "assignment_version": 0, "desired": self.assignment(), "dispatch_ready": False,
                "dispatch_rule_id": None, "observed_at": None,
                "failure_reason": "provider_outcome_unknown", "effect_in_progress": False}

    def state(self):
        return {"provider": {"enabled": False, "ready": False, "reason": "provider_management_disabled",
                             "number_purchase": False, "trunk_credentials_edit": False},
                "assignment_version": 0, "commands": [self.receipt()]}

    def test_exact_owned_routes_and_mirror_validate(self):
        validate_phone_provisioning_contract(self.openapi, self.schema)
        self.assertEqual((ROOT / "contracts/openapi/openapi.yaml").read_bytes(),
                         (ROOT / "docs/04-interfaces/openapi/openapi.yaml").read_bytes())

    def test_real_router_and_browser_use_the_documented_v1_routes(self):
        router = (ROOT / "apps/comms_web/lib/comms_web/router.ex").read_text()
        self.assertIn('scope "/api/v1", CommsWeb', router)
        matches = re.findall(r'(get|post)\(\s*"(/admin/telephony/provisioning[^\"]*)",\s*PhoneProvisioningController,', router)
        actual = {("/api/v1" + path.replace(":id", "{commandId}"), method) for method, path in matches}
        self.assertEqual(actual, set(OPERATIONS))
        browser = (ROOT / "clients/web/src/api/domains/telephony.ts").read_text()
        self.assertEqual(browser.count(PREFIX), 4)

    def test_valid_inspection_action_and_both_response_envelopes(self):
        inspection = {**self.assignment(), "reason": "Inspect acquired DID", "assignment_version": 0, "idempotency_key": UUID}
        for name, fixture in (("InspectPhoneProvisioningRequest", inspection),
                              ("PhoneProvisioningActionRequest", {"version": 1, "reason": "Apply verified setup"}),
                              ("PhoneProvisioningStateResponse", {"data": self.state()}),
                              ("PhoneProvisioningReceiptResponse", {"data": self.receipt()})):
            with self.subTest(name=name):
                self.validator(name).validate(fixture)
                Draft202012Validator(self.schema, format_checker=FormatChecker()).validate(fixture)

    def test_stable_inspection_key_must_be_uuid_and_assignment_version_nonnegative(self):
        fixture = {**self.assignment(), "reason": "Inspect bound DID", "assignment_version": 0, "idempotency_key": UUID}
        for key, value in (("idempotency_key", "repeat-me"), ("assignment_version", -1),
                           ("assignment_version", True), ("user_id", "foreign-claim")):
            with self.subTest(key=key, value=value):
                self.assertFalse(self.validator("InspectPhoneProvisioningRequest").is_valid({**fixture, key: value}))

    def test_action_requires_positive_receipt_cas_and_bounded_reason(self):
        for fixture in ({"version": 0, "reason": "Apply setup"}, {"version": True, "reason": "Apply setup"},
                        {"version": 1, "reason": "ab"}, {"version": 1, "reason": "x" * 501}, {"reason": "Apply setup"}):
            self.assertFalse(self.validator("PhoneProvisioningActionRequest").is_valid(fixture))

    def test_all_durable_outcomes_including_unconsumed_failure_remain_visible(self):
        for status in ("inspecting", "verified", "applying", "unknown", "applied", "failed", "reconciling"):
            self.validator("PhoneProvisioningReceipt").validate({**self.receipt(), "status": status})
        self.assertFalse(self.validator("PhoneProvisioningReceipt").is_valid({**self.receipt(), "status": "discarded"}))

    def test_secret_and_lease_authority_fields_are_rejected_everywhere(self):
        for field in ("auth_password", "api_secret", "lease_token", "lease_hash", "actor_session_id", "provider_url"):
            for name, fixture in (("PhoneProvisioningReceipt", self.receipt()),
                                  ("PhoneProvisioningAssignment", self.assignment()),
                                  ("PhoneProvisioningActionRequest", {"version": 1, "reason": "Apply setup"})):
                with self.subTest(field=field, name=name):
                    self.assertFalse(self.validator(name).is_valid({**fixture, field: "synthetic-do-not-expose"}))

    def test_client_provider_capabilities_cannot_claim_number_purchase_or_password_editing(self):
        for field in ("number_purchase", "trunk_credentials_edit"):
            provider = {**self.state()["provider"], field: True}
            self.assertFalse(self.validator("PhoneProvisioningProvider").is_valid(provider))

    def test_receipt_listing_and_provider_failure_projection_are_bounded(self):
        self.assertFalse(self.validator("PhoneProvisioningState").is_valid({**self.state(), "commands": [self.receipt()] * 11}))
        self.assertFalse(self.validator("PhoneProvisioningReceipt").is_valid({**self.receipt(), "failure_reason": "raw-provider-secret"}))
        self.assertFalse(self.validator("PhoneProvisioningReceipt").is_valid({**self.receipt(), "dispatch_rule_id": "https://foreign.invalid"}))

    def test_missing_auth_stepup_cas_or_cache_contract_is_detected(self):
        for field in ("security", "428", "409", "cache"):
            document = copy.deepcopy(self.openapi)
            operation = document["paths"][PREFIX + "/{commandId}/apply"]["post"]
            if field == "security":
                operation["security"] = []
            elif field == "cache":
                operation["responses"]["200"].pop("headers")
            else:
                operation["responses"].pop(field)
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_phone_provisioning_contract(document, self.schema)

    def test_route_typos_and_extra_effect_methods_are_detected(self):
        for mutation in ("missing-v1", "delete"):
            document = copy.deepcopy(self.openapi)
            if mutation == "missing-v1":
                document["paths"][PREFIX.replace("/v1", "")] = document["paths"].pop(PREFIX)
            else:
                document["paths"][PREFIX]["delete"] = document["paths"][PREFIX]["get"]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_phone_provisioning_contract(document, self.schema)

    def test_secret_schema_field_or_unbounded_command_projection_is_detected(self):
        for mutation in ("secret", "unbounded"):
            schema = copy.deepcopy(self.schema)
            if mutation == "secret":
                schema["$defs"]["PhoneProvisioningReceipt"]["properties"]["lease_token"] = {"type": "string"}
            else:
                schema["$defs"]["PhoneProvisioningState"]["properties"]["commands"].pop("maxItems")
            document = copy.deepcopy(self.openapi)
            document["components"]["schemas"].update(component_refs(schema["$defs"]))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_phone_provisioning_contract(document, schema)


class PhoneProvisioningReleaseContractTest(unittest.TestCase):
    def test_one_capability_is_additive_to_exact_member14_in_every_artifact_inventory(self):
        self.assertEqual(COMMUNICATION_ROLLBACK_CAPABILITIES, CURRENT)
        self.assertEqual(PROXMOX_CAPABILITIES, CURRENT)
        self.assertEqual(len(CURRENT.split(",")), 15)
        self.assertEqual(len(set(CURRENT.split(","))), 15)
        self.assertEqual(COMMUNICATION_ROLLBACK_CAPABILITY_HAZARDS[PHONE_CAPABILITY], ("telephony_provisioning_commands",))
        self.assertIn(f'io.k-comms.rollback-capabilities="{CURRENT}"', (ROOT / "Dockerfile").read_text())
        self.assertIn("K_COMMS_CAPABILITIES=" + CURRENT, (ROOT / "deploy/proxmox/bin/common.sh").read_text())
        for name in ("edge", "worker"):
            deployment = yaml.safe_load((ROOT / f"deploy/k8s/base/{name}-deployment.yaml").read_text())
            self.assertEqual(deployment["spec"]["template"]["metadata"]["annotations"]["k-comms.soyuz-tec.io/rollback-capabilities"], CURRENT)

    def test_immutable_proof_and_operator_parser_retain_phone_evidence(self):
        common = (ROOT / "deploy/proxmox/bin/common.sh").read_text()
        self.assertIn('podman image inspect "$1"', common)
        self.assertIn('assert_image_rollback_capabilities()', common)
        parser = (ROOT / "scripts/qualify_local_release.ps1").read_text()
        self.assertIn('"phone_provisioning_commands=[0-9]+ " +', parser)

    def test_member14_and_m1_remain_known_partial_targets_without_promoting_them(self):
        from test_validate_production_bundle import guest_rollback_operation
        for capabilities in (MEMBER14, ",".join(MEMBER14.split(",")[:12]), CURRENT):
            operation = guest_rollback_operation()
            env = operation["spec"]["template"]["spec"]["containers"][0]["env"]
            next(item for item in env if item["name"] == "K_COMMS_ROLLBACK_TARGET_CAPABILITIES")["value"] = capabilities
            errors = []
            validate_guest_rollback_preflight([operation], errors)
            self.assertEqual(errors, [], capabilities)

    def test_production_flag_cannot_claim_unqualified_provider_readiness(self):
        for value in ("true", "TRUE", True, " false "):
            errors = []
            validate_phone_provisioning_production_gate({"TELEPHONY_PROVISIONING_ENABLED": value}, errors)
            self.assertEqual(len(errors), 1)
        for data in ({}, {"TELEPHONY_PROVISIONING_ENABLED": "false"}):
            errors = []
            validate_phone_provisioning_production_gate(data, errors)
            self.assertEqual(errors, [])

    def test_platform_profiles_default_off_without_tenant_or_provider_credentials(self):
        for relative in ("base/configmap.yaml", "overlays/staging/configmap-patch.yaml", "overlays/production/configmap-patch.yaml"):
            data = yaml.safe_load((ROOT / "deploy/k8s" / relative).read_text())["data"]
            self.assertEqual(data["TELEPHONY_PROVISIONING_ENABLED"], "false")
            self.assertEqual(data["TELEPHONY_PROVISIONING_BINDINGS"], "{}")
        example = (ROOT / "deploy/proxmox/runtime.env.example").read_text()
        self.assertIn("TELEPHONY_PROVISIONING_ENABLED=false\n", example)
        self.assertIn("TELEPHONY_PROVISIONING_BINDINGS={}\n", example)

    def test_one_shots_override_inherited_provider_management_and_bindings(self):
        for relative in ("overlays/staging/migration-job.yaml", "overlays/production/migration-job.yaml",
                         "overlays/staging/bootstrap/bootstrap-job.yaml", "operations/platform-role/platform-role-job.yaml",
                         "operations/guest-rollback-preflight/guest-rollback-preflight-job.yaml",
                         "operations/attachment-restore-remap/restore-remap-job.yaml"):
            job = yaml.safe_load((ROOT / "deploy/k8s" / relative).read_text())
            env = {item["name"]: item.get("value") for item in job["spec"]["template"]["spec"]["containers"][0]["env"]}
            self.assertEqual(env["TELEPHONY_PROVISIONING_ENABLED"], "false")
            self.assertEqual(env["TELEPHONY_PROVISIONING_BINDINGS"], "{}")

    def test_phone_has_no_background_retry_or_orphan_job_owner(self):
        for relative in ("apps/comms_core/lib/comms_core/telephony/provisioning.ex",
                         "apps/comms_integrations/lib/comms_integrations/telephony/provisioning_live_kit.ex"):
            source = (ROOT / relative).read_text()
            self.assertNotRegex(source, r"\b(?:Oban|Outbox|RuntimePorts\.enqueue)\b")
        for path in (ROOT / "apps/comms_workers/lib").rglob("*.ex"):
            self.assertNotRegex(path.read_text(), r"(?i)(?:phone|telephony).*provisioning|telephony_provisioning_commands")


if __name__ == "__main__":
    unittest.main()
