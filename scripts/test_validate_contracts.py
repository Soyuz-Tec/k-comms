#!/usr/bin/env python3
"""Regression tests for security-sensitive OpenAPI contract invariants."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import unittest
from jsonschema import Draft202012Validator, FormatChecker

from validate_contracts import (
    CALL_REALTIME_MESSAGES,
    CONTRACTS,
    load_yaml,
    validate_call_contract,
    validate_call_realtime_contract,
    validate_guest_contract,
    validate_instant_room_contract,
    validate_instant_room_realtime_contract,
    validate_telephony_contract,
    validate_enterprise_identity_contract,
    validate_member_workflow_contract,
    validate_native_call_wake_contract,
    validate_refs,
    validate_whiteboard_contract,
    validate_whiteboard_realtime_contract,
)


class ReferenceValidationTests(unittest.TestCase):
    def test_missing_nested_operation_request_schema_is_rejected(self) -> None:
        document = {
            "paths": {
                "/conversation": {
                    "patch": {
                        "requestBody": {
                            "content": {
                                "application/json": {
                                    "schema": {"$ref": "#/components/schemas/Missing"}
                                }
                            }
                        }
                    }
                }
            },
            "components": {"schemas": {}},
        }
        with self.assertRaisesRegex(ValueError, "unresolved reference.*Missing"):
            validate_refs(document, Path("openapi.yaml"))

    def test_recursive_schema_references_resolve_against_the_original_root(self) -> None:
        document = {
            "$defs": {
                "Node": {
                    "type": "object",
                    "properties": {"next": {"$ref": "#/$defs/Node"}},
                }
            },
            "allOf": [{"$ref": "#/$defs/Node"}, {"$ref": "#"}],
        }
        validate_refs(document, Path("recursive.json"))

    def test_escaped_empty_and_array_pointer_segments_are_resolved(self) -> None:
        document = {
            "$defs": {
                "a/b~c": {"type": "string"},
                "~1": {"type": "number"},
                "space key": {"type": "boolean"},
                "": {"type": "null"},
            },
            "variants": [False, {"type": "object"}],
            "allOf": [
                {"$ref": "#/$defs/a~1b~0c"},
                {"$ref": "#/$defs/~01"},
                {"$ref": "#/$defs/space%20key"},
                {"$ref": "#/$defs/"},
                {"$ref": "#/variants/0"},
                {"$ref": "#/variants/1"},
            ],
        }
        validate_refs(document, Path("escaped.json"))

    def test_invalid_pointer_paths_escapes_and_array_indices_are_rejected(self) -> None:
        for ref in [
            "#/missing",
            "#/scalar/child",
            "#/a~2b",
            "#/a~",
            "#/variants/-",
            "#/variants/-1",
            "#/variants/01",
            "#/variants/1",
            "#/variants/\u0660",
        ]:
            with self.subTest(ref=ref):
                document = {
                    "scalar": 1,
                    "a~2b": {},
                    "a~": {},
                    "variants": [{}],
                    "nested": [{"$ref": ref}],
                }
                with self.assertRaisesRegex(ValueError, "unresolved reference"):
                    validate_refs(document, Path("invalid.json"))

    def test_yaml_alias_cycles_still_check_each_reachable_mapping(self) -> None:
        document = {"target": {}, "aliases": []}
        document["aliases"].append(document)
        document["aliases"].append({"$ref": "#/missing"})
        with self.assertRaisesRegex(ValueError, "unresolved reference.*missing"):
            validate_refs(document, Path("aliases.yaml"))
        document["aliases"][1]["$ref"] = "#/target"
        validate_refs(document, Path("aliases.yaml"))

    def test_missing_external_file_with_fragment_is_still_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "openapi.yaml"
            with self.assertRaisesRegex(ValueError, "unresolved reference.*missing.json"):
                validate_refs({"$ref": "missing.json#/$defs/Node"}, source)

    def test_existing_external_file_keeps_the_existing_existence_only_check(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "openapi.yaml"
            (source.parent / "schema.json").write_text("{}", encoding="utf-8")
            validate_refs({"nested": {"$ref": "schema.json#/$defs/Node"}}, source)


class ContractValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.openapi = load_yaml(CONTRACTS / "openapi" / "openapi.yaml")

    def test_current_guest_call_and_instant_room_contracts_pass(self) -> None:
        validate_call_contract(self.openapi)
        validate_guest_contract(self.openapi)
        validate_instant_room_contract(self.openapi)
        validate_whiteboard_contract(self.openapi)
        validate_telephony_contract(self.openapi)
        validate_enterprise_identity_contract(self.openapi)

    def test_current_member_workflow_contracts_and_standalone_schemas_pass(self) -> None:
        payloads = {
            path.name: json.loads(path.read_text())
            for path in (CONTRACTS / "json-schema").glob("*.json")
        }
        validate_member_workflow_contract(self.openapi, payloads)

    def test_private_workflow_routes_cannot_use_guest_or_service_authentication(self) -> None:
        for path, method in [
            ("/api/v1/me/workspace", "put"),
            ("/api/v1/me/onboarding", "patch"),
            ("/api/v1/admin/users/{userId}/role-preview", "post"),
            ("/api/v1/admin/usage", "get"),
            ("/api/v1/admin/deletion-requests/{requestId}/timeline", "get"),
        ]:
            for security in [[], [{"guestBearerAuth": []}], [{"serviceAccountAuth": []}]]:
                with self.subTest(path=path, security=security):
                    document = copy.deepcopy(self.openapi)
                    document["paths"][path][method]["security"] = security
                    with self.assertRaisesRegex(ValueError, "current human bearerAuth"):
                        validate_member_workflow_contract(document)

    def test_private_workspace_cas_and_bounds_cannot_be_removed(self) -> None:
        for name, key in [("ReplaceMemberWorkspaceRequest", "version"), ("UpdateMemberOnboardingRequest", "version")]:
            with self.subTest(name=name):
                document = copy.deepcopy(self.openapi)
                document["components"]["schemas"][name]["required"].remove(key)
                with self.assertRaisesRegex(ValueError, "exact private/allowlisted"):
                    validate_member_workflow_contract(document)
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["ReplaceMemberWorkspaceRequest"]["properties"]["contact_ids"].pop("maxItems")
        with self.assertRaisesRegex(ValueError, "contacts/groups bounds"):
            validate_member_workflow_contract(document)
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["PrivateContact"]["properties"]["email"] = {"type": "string"}
        with self.assertRaisesRegex(ValueError, "PrivateContact.*exact private/allowlisted"):
            validate_member_workflow_contract(document)

    def test_private_workspace_requests_require_cas_and_bounded_unique_people(self) -> None:
        payload = json.loads((CONTRACTS / "json-schema/member-workspace.v1.json").read_text())
        validator = Draft202012Validator({"$ref": "#/$defs/ReplaceMemberWorkspaceRequest", "$defs": payload["$defs"]}, format_checker=FormatChecker())
        person = "10000000-0000-4000-8000-000000000001"
        group = {"id": "10000000-0000-4000-8000-000000000002", "name": "Teammates", "member_ids": [person]}
        self.assertTrue(validator.is_valid({"version": 0, "contact_ids": [person], "groups": [group]}))
        for value in [
            {"contact_ids": [], "groups": []},
            {"version": -1, "contact_ids": [], "groups": []},
            {"version": "0", "contact_ids": [], "groups": []},
            {"version": 0, "contact_ids": [person, person], "groups": []},
            {"version": 0, "contact_ids": ["foreign-email@example.test"], "groups": []},
            {"version": 0, "contact_ids": [], "groups": [], "tenant_id": person},
            {"version": 0, "contact_ids": [person], "groups": [{**group, "role": "owner"}]},
        ]:
            with self.subTest(value=value):
                self.assertFalse(validator.is_valid(value))

    def test_role_preview_cannot_claim_authority_or_introduce_platform_roles(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["UserRoleChangePreview"]["properties"]["advisory"] = {"const": False}
        with self.assertRaisesRegex(ValueError, "remain advisory"):
            validate_member_workflow_contract(document)
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["FixedTenantRole"]["enum"].append("platform_admin")
        with self.assertRaisesRegex(ValueError, "custom or platform authority"):
            validate_member_workflow_contract(document)
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["RoleCapabilityFact"]["properties"]["conditions"].pop("allOf")
        with self.assertRaisesRegex(ValueError, "cannot omit current tenant"):
            validate_member_workflow_contract(document)
        payload = json.loads((CONTRACTS / "json-schema/role-permissions.v1.json").read_text())
        validator = Draft202012Validator({"$ref": "#/$defs/PreviewUserRoleRequest", "$defs": payload["$defs"]})
        for version in [1, "1", "+001"]:
            self.assertTrue(validator.is_valid({"role": "member", "version": version}))
        for value in [{"role": "member"}, {"role": "owner", "version": 0}, {"role": "platform_admin", "version": 1}, {"role": "member", "version": "1x"}, {"role": "member", "version": 1, "governance_review_required": False}]:
            self.assertFalse(validator.is_valid(value))

    def test_usage_requires_unavailable_null_and_denies_lifetime_completeness(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["UsageIdentitySource"]["oneOf"][1]["properties"]["data"] = {"type": "object"}
        with self.assertRaisesRegex(ValueError, "null data, never invented zero"):
            validate_member_workflow_contract(document)
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["UsageReport"]["properties"]["lifetime_complete"] = {"const": True}
        with self.assertRaisesRegex(ValueError, "deny lifetime completeness"):
            validate_member_workflow_contract(document)

    def test_usage_payload_cannot_expose_content_or_hide_missing_sources(self) -> None:
        payload = json.loads((CONTRACTS / "json-schema/usage-report.v1.json").read_text())
        validator = Draft202012Validator({"$ref": "#/$defs/UsageReport", "$defs": payload["$defs"]}, format_checker=FormatChecker())
        value = {
            "range": {"from": "2026-10-01", "through": "2026-10-05", "time_zone": "UTC"},
            "observed_at": "2026-10-05T10:00:00Z", "coverage": "currently_retained_records", "lifetime_complete": False,
            "sources": {source: {"status": "unavailable", "data": None} for source in ["identity", "conversations", "messages", "attachments", "calls", "telephony"]},
        }
        self.assertTrue(validator.is_valid(value))
        for change in ["invent_zero", "missing_source", "content", "lifetime", "timezone"]:
            broken = copy.deepcopy(value)
            if change == "invent_zero": broken["sources"]["identity"]["data"] = {"current": {"active_humans": 0}}
            elif change == "missing_source": broken["sources"].pop("telephony")
            elif change == "content": broken["sources"]["message_bodies"] = ["private text"]
            elif change == "lifetime": broken["lifetime_complete"] = True
            else: broken["range"]["time_zone"] = "Europe/London"
            with self.subTest(change=change): self.assertFalse(validator.is_valid(broken))
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["UsageMessagesCurrent"]["properties"]["message_body"] = {"type": "string"}
        with self.assertRaisesRegex(ValueError, "exact private/allowlisted"):
            validate_member_workflow_contract(document)

    def test_history_cannot_add_raw_metadata_errors_or_unbounded_proof_facts(self) -> None:
        for name, field, value, message in [
            ("DeletionHistoryEvent", "metadata", {"type": "object"}, "exact private/allowlisted"),
            ("DeletionHistoryEvent", "error_code", {"type": "string"}, "raw provider or worker errors"),
            ("DeletionHistoryEvidence", "provider_token", {"type": "string"}, "exact private/allowlisted"),
            ("DeletionHistoryCoverage", "version_lineage", {"const": "complete"}, "unproven retained coverage"),
        ]:
            with self.subTest(name=name, field=field):
                document = copy.deepcopy(self.openapi)
                document["components"]["schemas"][name]["properties"][field] = value
                with self.assertRaisesRegex(ValueError, message): validate_member_workflow_contract(document)
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["DeletionHistoryCounts"]["properties"]["deleted_object_count"].pop("maximum")
        with self.assertRaisesRegex(ValueError, "bounded allowlisted integers"):
            validate_member_workflow_contract(document)

    def test_history_event_payload_rejects_provider_text_and_arbitrary_evidence(self) -> None:
        payload = json.loads((CONTRACTS / "json-schema/deletion-request-history.v1.json").read_text())
        validator = Draft202012Validator({"$ref": "#/$defs/DeletionHistoryEvent", "$defs": payload["$defs"]}, format_checker=FormatChecker())
        event = {"id": "10000000-0000-4000-8000-000000000001", "actor": {"kind": "system", "user_id": None, "display_name": None}, "inserted_at": "2026-10-05T10:00:00Z", "action": "deletion_request.completed", "status": "completed", "attempt": 1, "error_code": None, "version": 2, "proof_versions": {"writer_fence_erasure_version": 1}, "counts": {"deleted_object_count": 0}}
        self.assertTrue(validator.is_valid(event))
        for field, value in [("error_code", "provider request included token abc"), ("metadata", {"token": "private"}), ("proof_versions", {"raw_provider_receipt": 1}), ("counts", {"deleted_object_count": 9_007_199_254_740_992}), ("action", "provider.secret_event")]:
            with self.subTest(field=field): self.assertFalse(validator.is_valid({**event, field: value}))

    def test_csv_receipts_cannot_drop_range_snapshot_coverage_or_truncation(self) -> None:
        for path, key in [("/api/v1/admin/usage/export", "x-usage-unavailable-sources"), ("/api/v1/admin/deletion-requests/{requestId}/timeline/export", "x-history-snapshot"), ("/api/v1/admin/deletion-requests/{requestId}/timeline/export", "x-export-truncated")]:
            with self.subTest(path=path, key=key):
                document = copy.deepcopy(self.openapi)
                document["paths"][path]["get"]["responses"]["200"]["headers"].pop(key)
                with self.assertRaisesRegex(ValueError, "receipt header"):
                    validate_member_workflow_contract(document)
        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/admin/usage/export"]["get"]["responses"]["200"]["x-csv-columns"].append("email")
        with self.assertRaisesRegex(ValueError, "allowlisted column order"):
            validate_member_workflow_contract(document)

    def test_standalone_private_schema_cannot_drift_from_canonical_wire_fields(self) -> None:
        payloads = {path.name: json.loads(path.read_text()) for path in (CONTRACTS / "json-schema").glob("*.json")}
        payloads["member-workspace.v1.json"]["$defs"]["PrivateContact"]["properties"]["email"] = {"type": "string"}
        with self.assertRaisesRegex(ValueError, "diverges from canonical OpenAPI"):
            validate_member_workflow_contract(self.openapi, payloads)

    def test_all_current_openapi_references_resolve(self) -> None:
        validate_refs(self.openapi, CONTRACTS / "openapi" / "openapi.yaml")

    def test_conversation_update_schema_requires_version_and_exact_settings(self) -> None:
        validator = Draft202012Validator(
            self.openapi["components"]["schemas"]["UpdateConversationRequest"]
        )
        for request in [
            {"version": 1},
            {"version": 2, "title": "x" * 160, "visibility": "tenant"},
            {"version": 1, "title": None, "visibility": "private"},
        ]:
            with self.subTest(request=request):
                self.assertTrue(validator.is_valid(request))
        for request in [
            {"title": "Team"},
            {"version": 0},
            {"version": 1.5},
            {"version": "1"},
            {"version": 1, "title": "x" * 161},
            {"version": 1, "title": 42},
            {"version": 1, "visibility": "public"},
            {"version": 1, "kind": "direct"},
            {"version": 1, "lock_version": 1},
        ]:
            with self.subTest(request=request):
                self.assertFalse(validator.is_valid(request))

    def test_membership_update_schema_requires_version_and_membership_role(self) -> None:
        validator = Draft202012Validator(
            self.openapi["components"]["schemas"]["UpdateConversationMemberRequest"]
        )
        for role in ["member", "moderator", "owner"]:
            self.assertTrue(validator.is_valid({"version": 1, "role": role}))
        for request in [
            {"role": "member"},
            {"version": 1},
            {"version": 0, "role": "member"},
            {"version": "1", "role": "member"},
            {"version": 1, "role": "admin"},
            {"version": 1, "role": None},
            {"version": 1, "role": "member", "user_id": "another-user"},
        ]:
            with self.subTest(request=request):
                self.assertFalse(validator.is_valid(request))

    def test_factor_challenge_cannot_regress_to_session_or_expose_credentials(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/sessions"]["post"]["responses"]["200"]["content"]["application/json"]["schema"] = {"$ref": "#/components/schemas/TokenResponse"}
        with self.assertRaisesRegex(ValueError, "distinguish a session"):
            validate_enterprise_identity_contract(document)

        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["MfaChallenge"]["properties"]["access_token"] = {"type": "string"}
        with self.assertRaisesRegex(ValueError, "contain no session credentials"):
            validate_enterprise_identity_contract(document)

    def test_scim_cannot_use_a_human_session_drop_version_or_grant_roles(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["paths"]["/scim/v2/Users"]["post"]["security"] = [{"bearerAuth": []}]
        with self.assertRaisesRegex(ValueError, "dedicated tenant-scoped service"):
            validate_enterprise_identity_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/scim/v2/Users/{scimId}"]["put"]["parameters"] = []
        with self.assertRaisesRegex(ValueError, "observed resource version"):
            validate_enterprise_identity_contract(document)

        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["ScimUserCreate"]["properties"]["roles"] = {"type": "array"}
        with self.assertRaisesRegex(ValueError, "cannot grant application authority"):
            validate_enterprise_identity_contract(document)

    def test_telephony_control_state_cannot_add_provider_states(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["TelephonyCall"]["properties"]["control_state"]["enum"].append("ari_channel")
        with self.assertRaisesRegex(ValueError, "bounded control state"):
            validate_telephony_contract(document)

    def test_telephony_contract_requires_human_auth_and_separate_provider_auth(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/telephony/calls/{callId}/answer"]["post"]["security"] = []
        with self.assertRaisesRegex(ValueError, "requires bearerAuth"):
            validate_telephony_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/telephony/livekit/webhook"]["post"]["security"] = [{"bearerAuth": []}]
        with self.assertRaisesRegex(ValueError, "separate livekitWebhookAuth"):
            validate_telephony_contract(document)

    def test_telephony_projection_cannot_expose_provider_room_or_token(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["TelephonyCall"]["properties"]["provider_room"] = {"type": "string"}
        with self.assertRaisesRegex(ValueError, "frozen individual call projection"):
            validate_telephony_contract(document)

    def test_telephony_start_cannot_drop_idempotency_key(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["StartTelephonyCallRequest"]["required"].remove("idempotency_key")
        with self.assertRaisesRegex(ValueError, "destination and idempotency key"):
            validate_telephony_contract(document)

    def test_telephony_provider_callback_documents_exact_body_binding(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/telephony/livekit/webhook"]["post"]["description"] = "Accept JSON."
        with self.assertRaisesRegex(ValueError, "body-bound provider attribution"):
            validate_telephony_contract(document)

    def test_whiteboard_contract_rejects_unbounded_or_unsafe_scene_data(self) -> None:
        openapi = copy.deepcopy(self.openapi)
        elements = openapi["components"]["schemas"]["WhiteboardScenePayload"][
            "properties"
        ]["elements"]
        elements.pop("maxItems")

        with self.assertRaisesRegex(ValueError, "bounded to 200"):
            validate_whiteboard_contract(openapi)

        openapi = copy.deepcopy(self.openapi)
        openapi["components"]["schemas"]["WhiteboardElement"]["properties"][
            "type"
        ]["enum"].append("iframe")

        with self.assertRaisesRegex(ValueError, "safe SDK subset"):
            validate_whiteboard_contract(openapi)

    def test_whiteboard_images_require_an_approved_asset_and_reject_remote_data(self) -> None:
        for field in ["fileId", "dataURL", "src", "url"]:
            with self.subTest(field=field):
                document = copy.deepcopy(self.openapi)
                condition = document["components"]["schemas"]["WhiteboardElement"]["allOf"][0]
                condition["then"]["properties"].pop(field)
                with self.assertRaisesRegex(ValueError, "durable asset UUID"):
                    validate_whiteboard_contract(document)

    def test_whiteboard_image_schema_accepts_only_uuid_asset_references(self) -> None:
        schema = self.openapi["components"]["schemas"]["WhiteboardElement"]
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        image = {"id": "image-element", "type": "image", "version": 1, "versionNonce": 1,
                 "fileId": "00000000-0000-4000-8000-000000000001", "link": None, "customData": None}
        self.assertTrue(validator.is_valid(image))
        for changes in [{"fileId": None}, {"fileId": "foreign-object-key"},
                        {"dataURL": "data:image/png;base64,dW5hcHByb3ZlZA=="},
                        {"src": "https://foreign.example.test/image.png"},
                        {"url": "https://foreign.example.test/image.png"}]:
            with self.subTest(changes=changes):
                self.assertFalse(validator.is_valid({**image, **changes}))
        image.pop("fileId")
        self.assertFalse(validator.is_valid(image))

    def test_telephony_transfer_schema_preserves_e164_and_queue_policy(self) -> None:
        schema = self.openapi["components"]["schemas"]["TelephonyControlRequest"]
        validator = Draft202012Validator(schema)
        request = {"action": "blind_transfer", "idempotency_key": "transfer-one", "destination": "+441234567890"}
        self.assertTrue(validator.is_valid(request))
        for destination in ["sip:member@foreign.example.test", "441234567890", "+1", "\\441234567890"]:
            self.assertFalse(validator.is_valid({**request, "destination": destination}))
        route = {"name": "Support", "mode": "queue", "policy": "round_robin",
                 "member_ids": ["00000000-0000-4000-8000-000000000001"], "max_waiting": 10,
                 "max_wait_seconds": 60, "enabled": True, "reason": "Reviewed route"}
        validator = Draft202012Validator(self.openapi["components"]["schemas"]["TelephonyRouteRequest"])
        self.assertTrue(validator.is_valid(route))
        self.assertFalse(validator.is_valid({**route, "policy": "simultaneous"}))
        self.assertTrue(validator.is_valid({**route, "mode": "shared_line", "policy": "simultaneous"}))

    def test_attachment_only_messages_require_at_least_one_bounded_attachment(self) -> None:
        schema = copy.deepcopy(self.openapi["components"]["schemas"]["SendMessageRequest"])
        # The metadata reference is irrelevant to these message-content vectors.
        schema["properties"].pop("metadata")
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        attachment = "00000000-0000-4000-8000-000000000001"
        for message in [{"body": "Text"}, {"body": "", "attachment_ids": [attachment]},
                        {"body": None, "attachment_ids": [attachment]}, {"attachment_ids": [attachment]}]:
            self.assertTrue(validator.is_valid(message))
        for message in [{}, {"body": ""}, {"body": "   "}, {"attachment_ids": []},
                        {"body": "", "attachment_ids": [attachment] * 21}]:
            self.assertFalse(validator.is_valid(message))

    def test_guest_whiteboard_contract_is_server_scoped_and_authenticated(self) -> None:
        openapi = copy.deepcopy(self.openapi)
        guest_path = "/api/v1/guest/conversation/whiteboard/operations"
        openapi["paths"][guest_path]["get"]["security"] = []

        with self.assertRaisesRegex(ValueError, "guestBearerAuth"):
            validate_whiteboard_contract(openapi)

        openapi = copy.deepcopy(self.openapi)
        openapi["paths"][guest_path]["parameters"] = [
            {"name": "conversationId", "in": "path", "required": True}
        ]

        with self.assertRaisesRegex(ValueError, "server-scoped"):
            validate_whiteboard_contract(openapi)

    def test_conversation_counterpart_id_is_nullable_and_uuid_shaped(self) -> None:
        conversation = self.openapi["components"]["schemas"]["Conversation"]
        self.assertIn("counterpart_user_id", conversation["required"])
        self.assertEqual(
            conversation["properties"]["counterpart_user_id"],
            {
                "type": ["string", "null"],
                "format": "uuid",
                "description": (
                    "Server-derived current counterpart identifier for an authorized "
                    "direct conversation; null for non-direct conversations."
                ),
            },
        )

    def test_guest_link_creation_requires_runtime_conversion_metadata(self) -> None:
        document = copy.deepcopy(self.openapi)
        data = document["components"]["schemas"]["GuestLinkCreationResponse"][
            "properties"
        ]["data"]
        data["required"].remove("conversion_enabled")
        data["properties"].pop("conversion_enabled")

        with self.assertRaisesRegex(ValueError, "GuestLinkCreationResponse"):
            validate_guest_contract(document)

    def test_guest_logout_documents_atomic_authority_cleanup(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/guest/sessions/current"]["delete"][
            "responses"
        ]["204"]["description"] = "Current guest session revoked."

        with self.assertRaisesRegex(ValueError, "atomic scoped-authority cleanup"):
            validate_guest_contract(document)

    def test_guest_response_secrets_cannot_regress_to_write_only(self) -> None:
        mutations = {
            "creation token": (
                "GuestLinkCreationResponse",
                ("properties", "token"),
            ),
            "creation share URL": (
                "GuestLinkCreationResponse",
                ("properties", "share_url"),
            ),
            "creation conversion verification code": (
                "GuestLinkCreationResponse",
                ("properties", "conversion_verification_code"),
            ),
            "nested creation share URL": (
                "GuestLinkCreationResponse",
                ("properties", "data", "properties", "share_url"),
            ),
            "guest access token": (
                "GuestSessionResponse",
                ("properties", "access_token"),
            ),
            "guest refresh token": (
                "GuestSessionResponse",
                ("properties", "refresh_token"),
            ),
            "guest socket ticket": (
                "SocketTicketResponse",
                ("properties", "data", "properties", "ticket"),
            ),
        }

        for label, (schema_name, path) in mutations.items():
            with self.subTest(label=label):
                document = copy.deepcopy(self.openapi)
                value = document["components"]["schemas"][schema_name]
                for key in path:
                    value = value[key]
                value.pop("readOnly")
                value["writeOnly"] = True

                with self.assertRaises(ValueError):
                    validate_guest_contract(document)

    def test_guest_conversion_requires_a_separate_write_only_verification_code(
        self,
    ) -> None:
        document = copy.deepcopy(self.openapi)
        request = document["components"]["schemas"][
            "ConvertVerifiedGuestAccountRequest"
        ]
        request["required"].remove("verification_code")

        with self.assertRaisesRegex(
            ValueError, "ConvertVerifiedGuestAccountRequest"
        ):
            validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        verification_code = document["components"]["schemas"][
            "ConvertVerifiedGuestAccountRequest"
        ]["properties"]["verification_code"]
        verification_code.pop("writeOnly")
        verification_code["readOnly"] = True

        with self.assertRaisesRegex(
            ValueError, "ConvertVerifiedGuestAccountRequest"
        ):
            validate_guest_contract(document)

    def test_conversion_verification_secret_stays_out_of_reusable_link_projection(
        self,
    ) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["GuestLink"]["properties"][
            "conversion_verification_code"
        ] = {"type": "string"}

        with self.assertRaisesRegex(ValueError, "GuestLink must never expose"):
            validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        creation_data = document["components"]["schemas"][
            "GuestLinkCreationResponse"
        ]["properties"]["data"]["properties"]
        creation_data["conversion_verification_code"] = {"type": "string"}

        with self.assertRaisesRegex(ValueError, "GuestLinkCreationResponse"):
            validate_guest_contract(document)

    def test_guest_link_preview_cannot_expose_internal_metadata(self) -> None:
        forbidden_fields = (
            "tenant",
            "tenant_id",
            "conversation",
            "conversation_id",
            "kind",
            "visibility",
            "latest_sequence",
            "version",
            "inserted_at",
            "updated_at",
            "capabilities",
        )

        for field in forbidden_fields:
            with self.subTest(field=field):
                document = copy.deepcopy(self.openapi)
                data = document["components"]["schemas"]["GuestLinkPreviewResponse"][
                    "properties"
                ]["data"]
                data["required"].append(field)
                data["properties"][field] = {"type": "string"}

                with self.assertRaisesRegex(
                    ValueError, "minimal pre-admission projection"
                ):
                    validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        data = document["components"]["schemas"]["GuestLinkPreviewResponse"][
            "properties"
        ]["data"]
        data["required"].remove("email_hint")
        data["properties"].pop("email_hint")

        with self.assertRaisesRegex(ValueError, "GuestLinkPreviewResponse"):
            validate_guest_contract(document)

    def test_guest_call_ttl_is_split_from_human_call_ttl(self) -> None:
        mutations = (
            ("GuestAudioCallCredential", 60),
            ("AudioCallCredential", 1),
        )
        for schema_name, minimum in mutations:
            with self.subTest(schema=schema_name):
                document = copy.deepcopy(self.openapi)
                document["components"]["schemas"][schema_name]["properties"][
                    "expires_in"
                ]["minimum"] = minimum

                with self.assertRaisesRegex(ValueError, schema_name):
                    validate_call_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/guest/conversation/calls"]["post"]["responses"][
            "201"
        ]["content"]["application/json"]["schema"][
            "$ref"
        ] = "#/components/schemas/AudioCallCredentialResponse"

        with self.assertRaisesRegex(ValueError, "GuestAudioCallCredentialResponse"):
            validate_call_contract(document)

    def test_call_response_secrets_cannot_regress_to_write_only(self) -> None:
        for schema_name in ("AudioCallCredential", "GuestAudioCallCredential"):
            with self.subTest(schema=schema_name):
                document = copy.deepcopy(self.openapi)
                participant_token = document["components"]["schemas"][schema_name][
                    "properties"
                ]["participant_token"]
                participant_token.pop("readOnly")
                participant_token["writeOnly"] = True

                with self.assertRaisesRegex(ValueError, schema_name):
                    validate_call_contract(document)

    def test_guest_socket_ttl_is_split_from_human_socket_ttl(self) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["SocketTicketResponse"]["properties"]["data"][
            "properties"
        ]["expires_in"]["minimum"] = 10
        with self.assertRaisesRegex(ValueError, "guest socket tickets"):
            validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/socket-tickets"]["post"]["responses"]["201"][
            "content"
        ]["application/json"]["schema"]["properties"]["data"]["properties"][
            "expires_in"
        ]["minimum"] = 1
        with self.assertRaisesRegex(ValueError, "human 10..120"):
            validate_guest_contract(document)

    def test_token_response_matches_runtime_and_conversion_keeps_reference(
        self,
    ) -> None:
        document = copy.deepcopy(self.openapi)
        token_response = document["components"]["schemas"]["TokenResponse"]
        token_response["required"].append("capabilities")
        token_response["properties"]["capabilities"] = {
            "$ref": "#/components/schemas/UserCapabilities"
        }
        with self.assertRaisesRegex(ValueError, "runtime authentication payload"):
            validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["GuestAccountConversionResponse"][
            "properties"
        ]["authentication"]["$ref"] = "#/components/schemas/GuestSessionResponse"
        with self.assertRaisesRegex(ValueError, "must use TokenResponse"):
            validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        token_user = document["components"]["schemas"]["TokenResponse"][
            "properties"
        ]["user"]
        token_user["required"].remove("access_scope")
        token_user["properties"].pop("access_scope")
        with self.assertRaisesRegex(ValueError, "access_scope"):
            validate_guest_contract(document)


class InstantRoomContractValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.openapi = load_yaml(CONTRACTS / "openapi" / "openapi.yaml")

    def test_repository_instant_room_contract_passes(self) -> None:
        validate_instant_room_contract(copy.deepcopy(self.openapi))

    def test_create_and_join_require_the_exact_idempotency_parameter(self) -> None:
        for path in (
            "/api/v1/instant-rooms",
            "/api/v1/instant-room-sessions",
        ):
            with self.subTest(path=path):
                document = copy.deepcopy(self.openapi)
                document["paths"][path]["post"]["parameters"] = []

                with self.assertRaisesRegex(ValueError, "idempotency headers"):
                    validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        schema = document["components"]["parameters"]["RequiredIdempotencyKey"][
            "schema"
        ]
        schema["maxLength"] = 64

        with self.assertRaisesRegex(ValueError, "256-bit Base64URL"):
            validate_instant_room_contract(document)

    def test_all_operations_require_trusted_origin_and_preview_omits_idempotency(
        self,
    ) -> None:
        document = copy.deepcopy(self.openapi)
        origin = document["components"]["parameters"]["RequiredTrustedOrigin"]
        origin["required"] = False

        with self.assertRaisesRegex(ValueError, "RequiredTrustedOrigin"):
            validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/instant-rooms/preview"]["post"][
            "parameters"
        ].append({"$ref": "#/components/parameters/RequiredIdempotencyKey"})

        with self.assertRaisesRegex(ValueError, "idempotency headers"):
            validate_instant_room_contract(document)

    def test_preview_does_not_expose_internal_fields(self) -> None:
        document = copy.deepcopy(self.openapi)
        data = document["components"]["schemas"]["InstantRoomPreviewResponse"][
            "properties"
        ]["data"]
        data["required"].append("tenant_id")
        data["properties"]["tenant_id"] = {"type": "string", "format": "uuid"}

        with self.assertRaisesRegex(ValueError, "minimal public projection"):
            validate_instant_room_contract(document)

    def test_active_room_deadlines_remain_nullable(self) -> None:
        for schema_path in (
            (
                "InstantRoom",
                "properties",
                "expires_at",
            ),
            (
                "InstantRoomPreviewResponse",
                "properties",
                "data",
                "properties",
                "expires_at",
            ),
        ):
            with self.subTest(schema=schema_path[0]):
                document = copy.deepcopy(self.openapi)
                value = document["components"]["schemas"]
                for key in schema_path:
                    value = value[key]
                value["type"] = "string"

                with self.assertRaises(ValueError):
                    validate_instant_room_contract(document)

    def test_feature_tenant_and_dependency_failures_share_one_503_code(
        self,
    ) -> None:
        document = copy.deepcopy(self.openapi)
        document["components"]["schemas"]["InstantRoomsUnavailableError"][
            "properties"
        ]["error"]["properties"]["code"]["const"] = "service_unavailable"

        with self.assertRaisesRegex(ValueError, "share one exact public error"):
            validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/instant-rooms"]["post"]["responses"][
            "503"
        ] = {"$ref": "#/components/responses/Error"}

        with self.assertRaisesRegex(ValueError, "fail-closed public"):
            validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/guest/account"]["post"]["responses"][
            "503"
        ] = {"$ref": "#/components/responses/Error"}

        with self.assertRaisesRegex(ValueError, "fail-closed public"):
            validate_instant_room_contract(document)

    def test_join_tokens_remain_exact_write_only_secrets(self) -> None:
        document = copy.deepcopy(self.openapi)
        token = document["components"]["schemas"]["InstantRoomTokenRequest"][
            "properties"
        ]["token"]
        token.pop("writeOnly")
        token["readOnly"] = True

        with self.assertRaisesRegex(ValueError, "exact write-only 256-bit"):
            validate_instant_room_contract(document)

    def test_anonymous_device_requirements_are_explicit(self) -> None:
        document = copy.deepcopy(self.openapi)
        device = document["components"]["schemas"]["InstantRoomDevice"]
        device["required"].remove("platform")

        with self.assertRaisesRegex(ValueError, "device requirements"):
            validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        join = document["components"]["schemas"][
            "CreateInstantRoomSessionRequest"
        ]
        join["description"] = "Join an instant room."

        with self.assertRaisesRegex(ValueError, "auth-dependent"):
            validate_instant_room_contract(document)

    def test_anonymous_creator_display_name_is_explicit(self) -> None:
        document = copy.deepcopy(self.openapi)
        create = document["components"]["schemas"]["CreateInstantRoomRequest"]
        create["description"] = create["description"].replace(
            " and a chosen display_name", ""
        )

        with self.assertRaisesRegex(ValueError, "device requirements"):
            validate_instant_room_contract(document)

    def test_creation_token_and_share_url_remain_response_only(self) -> None:
        for field in ("token", "share_url"):
            with self.subTest(field=field):
                document = copy.deepcopy(self.openapi)
                secret = document["components"]["schemas"][
                    "InstantRoomCreationResponse"
                ]["properties"][field]
                secret.pop("readOnly")
                secret["writeOnly"] = True

                with self.assertRaisesRegex(ValueError, "response-only"):
                    validate_instant_room_contract(document)

    def test_conflict_contract_covers_fingerprint_and_expired_replay(self) -> None:
        document = copy.deepcopy(self.openapi)
        del document["components"]["responses"]["InstantRoomConflict"]["content"][
            "application/json"
        ]["examples"]["replay_expired"]

        with self.assertRaisesRegex(ValueError, "idempotency_replay_expired"):
            validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/instant-room-sessions"]["post"]["responses"][
            "409"
        ] = {"$ref": "#/components/responses/Error"}

        with self.assertRaisesRegex(ValueError, "idempotency contract"):
            validate_instant_room_contract(document)

    def test_public_throttling_requires_retry_after(self) -> None:
        document = copy.deepcopy(self.openapi)
        retry_after = document["components"]["responses"][
            "InstantRoomRateLimited"
        ]["headers"]["Retry-After"]
        retry_after["required"] = False

        with self.assertRaisesRegex(ValueError, "positive integer Retry-After"):
            validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        rate_error = document["components"]["schemas"][
            "InstantRoomRateLimitedError"
        ]["properties"]["error"]["properties"]
        rate_error["code"]["const"] = "too_many_requests"

        with self.assertRaisesRegex(ValueError, "exact runtime body"):
            validate_instant_room_contract(document)

        document = copy.deepcopy(self.openapi)
        document["paths"]["/api/v1/instant-room-sessions"]["post"]["responses"][
            "429"
        ] = {"$ref": "#/components/responses/Error"}

        with self.assertRaisesRegex(ValueError, "Retry-After contract"):
            validate_instant_room_contract(document)

        for path in (
            "/api/v1/guest/account",
            "/api/v1/guest/conversation/messages",
        ):
            with self.subTest(path=path):
                document = copy.deepcopy(self.openapi)
                document["paths"][path]["post"]["responses"]["429"] = {
                    "$ref": "#/components/responses/Error"
                }

                with self.assertRaisesRegex(ValueError, "Retry-After contract"):
                    validate_instant_room_contract(document)

    def test_same_tenant_conversation_scope_controls_direct_create_and_join(
        self,
    ) -> None:
        for path in (
            "/api/v1/instant-rooms",
            "/api/v1/instant-room-sessions",
        ):
            with self.subTest(path=path):
                document = copy.deepcopy(self.openapi)
                document["paths"][path]["post"]["description"] = (
                    "Any configured-tenant human receives direct room access."
                )

                with self.assertRaisesRegex(
                    ValueError, "same-tenant conversation-only identity reuse"
                ):
                    validate_instant_room_contract(document)

    def test_unsupported_json_media_type_is_documented(self) -> None:
        document = copy.deepcopy(self.openapi)
        del document["paths"]["/api/v1/instant-rooms/preview"]["post"][
            "responses"
        ]["415"]

        with self.assertRaisesRegex(ValueError, "unsupported application/json"):
            validate_instant_room_contract(document)

    def test_instant_conversion_cannot_claim_verified_email_or_workspace_scope(
        self,
    ) -> None:
        document = copy.deepcopy(self.openapi)
        request = document["components"]["schemas"][
            "ConvertInstantRoomGuestAccountRequest"
        ]
        request["required"].append("verification_code")
        request["properties"]["verification_code"] = {
            "type": "string",
            "writeOnly": True,
        }

        with self.assertRaisesRegex(ValueError, "omit verification claims"):
            validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        request = document["components"]["schemas"][
            "ConvertInstantRoomGuestAccountRequest"
        ]
        request["description"] = request["description"].replace(
            "conversation-only", "workspace"
        )

        with self.assertRaisesRegex(ValueError, "conversation-only"):
            validate_guest_contract(document)

    def test_status_capability_documents_the_fail_closed_production_gate(
        self,
    ) -> None:
        document = copy.deepcopy(self.openapi)
        instant_rooms = document["components"]["schemas"]["StatusResponse"][
            "properties"
        ]["capabilities"]["properties"]["instant_rooms"]
        instant_rooms["description"] = "Instant rooms are enabled."

        with self.assertRaisesRegex(ValueError, "fail-closed production gate"):
            validate_instant_room_contract(document)


class WhiteboardRealtimeContractValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.asyncapi = load_yaml(CONTRACTS / "asyncapi" / "asyncapi.yaml")

    def test_repository_whiteboard_realtime_contract_passes(self) -> None:
        validate_whiteboard_realtime_contract(copy.deepcopy(self.asyncapi))

    def test_rejects_missing_durable_operation_signal(self) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        del asyncapi["channels"]["whiteboard"]["messages"]["operationApplied"]

        with self.assertRaisesRegex(ValueError, "operation and presence"):
            validate_whiteboard_realtime_contract(asyncapi)

    def test_rejects_untyped_pointer_tool(self) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        del asyncapi["components"]["schemas"]["WhiteboardPointer"]["properties"][
            "tool"
        ]["enum"]

        with self.assertRaisesRegex(ValueError, "bounded and typed"):
            validate_whiteboard_realtime_contract(asyncapi)

    def test_rejects_presence_without_device_identity(self) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        presence = asyncapi["components"]["schemas"]["WhiteboardPresencePayload"]
        presence["required"].remove("device_id")
        presence["properties"].pop("device_id")

        with self.assertRaisesRegex(ValueError, "authorized user and device"):
            validate_whiteboard_realtime_contract(asyncapi)


class CallRealtimeContractValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.asyncapi = load_yaml(CONTRACTS / "asyncapi" / "asyncapi.yaml")

    def test_repository_call_realtime_contract_passes(self) -> None:
        validate_call_realtime_contract(copy.deepcopy(self.asyncapi))

    def test_rejects_each_call_event_omitted_from_conversation_channel(self) -> None:
        for channel_key in CALL_REALTIME_MESSAGES:
            with self.subTest(channel_key=channel_key):
                asyncapi = copy.deepcopy(self.asyncapi)
                del asyncapi["channels"]["conversation"]["messages"][channel_key]

                with self.assertRaises(ValueError) as raised:
                    validate_call_realtime_contract(asyncapi)

                self.assertIn(
                    f"missing call lifecycle message {channel_key}",
                    str(raised.exception),
                )

    def test_rejects_each_call_event_omitted_from_receive_operation(self) -> None:
        for channel_key in CALL_REALTIME_MESSAGES:
            with self.subTest(channel_key=channel_key):
                asyncapi = copy.deepcopy(self.asyncapi)
                omitted_ref = f"#/channels/conversation/messages/{channel_key}"
                messages = asyncapi["operations"]["receiveConversationEvent"][
                    "messages"
                ]
                asyncapi["operations"]["receiveConversationEvent"]["messages"] = [
                    message
                    for message in messages
                    if message.get("$ref") != omitted_ref
                ]

                with self.assertRaises(ValueError) as raised:
                    validate_call_realtime_contract(asyncapi)

                self.assertIn(omitted_ref, str(raised.exception))

    def test_rejects_payload_field_omission(self) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        del asyncapi["components"]["schemas"]["CallEndedPayload"]["properties"][
            "end_reason"
        ]

        with self.assertRaisesRegex(
            ValueError,
            "CallEndedPayload must exactly match",
        ):
            validate_call_realtime_contract(asyncapi)

    def test_rejects_video_compatibility_alias(self) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        asyncapi["components"]["schemas"]["AudioCallStartedPayload"]["allOf"][1][
            "properties"
        ]["media_kind"]["const"] = "video"

        with self.assertRaisesRegex(
            ValueError,
            "AudioCallStartedPayload must remain an audio-only compatibility alias",
        ):
                validate_call_realtime_contract(asyncapi)


class InstantRoomRealtimeContractValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.asyncapi = load_yaml(CONTRACTS / "asyncapi" / "asyncapi.yaml")

    def test_repository_instant_room_realtime_contract_passes(self) -> None:
        validate_instant_room_realtime_contract(copy.deepcopy(self.asyncapi))

    def test_rejects_presence_event_omitted_from_channel(self) -> None:
        for channel_key in ("presenceState", "presenceDiff"):
            with self.subTest(channel_key=channel_key):
                asyncapi = copy.deepcopy(self.asyncapi)
                del asyncapi["channels"]["conversation"]["messages"][channel_key]

                with self.assertRaisesRegex(
                    ValueError, f"missing instant-room message {channel_key}"
                ):
                    validate_instant_room_realtime_contract(asyncapi)

    def test_rejects_presence_event_omitted_from_receive_operation(self) -> None:
        for channel_key in ("presenceState", "presenceDiff"):
            with self.subTest(channel_key=channel_key):
                asyncapi = copy.deepcopy(self.asyncapi)
                omitted_ref = f"#/channels/conversation/messages/{channel_key}"
                messages = asyncapi["operations"]["receiveConversationEvent"][
                    "messages"
                ]
                asyncapi["operations"]["receiveConversationEvent"]["messages"] = [
                    message
                    for message in messages
                    if message.get("$ref") != omitted_ref
                ]

                with self.assertRaisesRegex(ValueError, omitted_ref):
                    validate_instant_room_realtime_contract(asyncapi)

    def test_presence_metadata_cannot_expose_connection_identifiers(self) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        meta = asyncapi["components"]["schemas"]["PresenceMeta"]
        meta["required"].append("connection_id")
        meta["properties"]["connection_id"] = {"type": "string"}

        with self.assertRaisesRegex(
            ValueError, "optional opaque Phoenix phx_ref"
        ):
            validate_instant_room_realtime_contract(asyncapi)

    def test_presence_transport_refs_remain_optional_opaque_phoenix_fields(
        self,
    ) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        del asyncapi["components"]["schemas"]["PresenceMeta"]["properties"][
            "phx_ref"
        ]

        with self.assertRaisesRegex(
            ValueError, "optional opaque Phoenix phx_ref"
        ):
            validate_instant_room_realtime_contract(asyncapi)

    def test_presence_state_keys_remain_user_uuids(self) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        asyncapi["components"]["schemas"]["PresenceStatePayload"].pop(
            "propertyNames"
        )

        with self.assertRaisesRegex(ValueError, "user-UUID map"):
            validate_instant_room_realtime_contract(asyncapi)

    def test_durable_lifecycle_evidence_is_not_advertised_as_client_realtime(
        self,
    ) -> None:
        asyncapi = copy.deepcopy(self.asyncapi)
        asyncapi["channels"]["conversation"]["messages"][
            "ephemeralRoomExpired"
        ] = {"$ref": "#/components/messages/EphemeralRoomExpired"}

        with self.assertRaisesRegex(
            ValueError, "durable instant-room lifecycle evidence"
        ):
            validate_instant_room_realtime_contract(asyncapi)


class NativeWakeContractTests(unittest.TestCase):
    def setUp(self):
        self.open = load_yaml(CONTRACTS / "openapi" / "openapi.yaml")
        self.standalone = json.loads((CONTRACTS / "json-schema" / "native-call-wake.v1.json").read_text())

    def test_actual_current_owner_paths_and_safe_schema_mirrors(self):
        validate_native_call_wake_contract(self.open, self.standalone)

    def test_native_route_cannot_become_anonymous_or_generic_auth_response(self):
        for field, value in [("security", [{}]), ("operationId", "createSession")]:
            altered = copy.deepcopy(self.open)
            altered["paths"]["/api/v1/native-call-wakes/{wakeId}/admit"]["post"][field] = value
            with self.assertRaisesRegex(ValueError, "current member bearer"):
                validate_native_call_wake_contract(altered, self.standalone)

    def test_private_material_cannot_enter_a_read_projection_or_push_hint(self):
        for name, field in [("NativePushRegistration", "token_hash"), ("NativeCallWakeHint", "caller")]:
            altered = copy.deepcopy(self.open)
            altered["components"]["schemas"][name]["properties"][field] = {"type": "string"}
            with self.assertRaisesRegex(ValueError, "private|opaque"):
                validate_native_call_wake_contract(altered, self.standalone)

    def test_provider_token_cannot_lose_write_only_contract(self):
        altered = copy.deepcopy(self.open)
        altered["components"]["schemas"]["NativePushRegistrationRequest"]["properties"]["token"].pop("writeOnly")
        with self.assertRaisesRegex(ValueError, "write-only"):
            validate_native_call_wake_contract(altered, self.standalone)

    def test_standalone_hint_rejects_caller_credential_and_malformed_identity(self):
        validator = Draft202012Validator(self.standalone, format_checker=FormatChecker())
        payload = {"protocol_version": "1", "wake_id": "00000000-0000-4000-8000-000000000001", "expires_at": "2026-10-05T00:00:25Z", "kind": "call"}
        self.assertFalse(list(validator.iter_errors(payload)))
        for changed in [payload | {"caller": "Private caller"}, payload | {"participant_token": "not-authority"}, payload | {"wake_id": "invalid"}, payload | {"protocol_version": 1}]:
            self.assertTrue(list(validator.iter_errors(changed)))


if __name__ == "__main__":
    unittest.main()
