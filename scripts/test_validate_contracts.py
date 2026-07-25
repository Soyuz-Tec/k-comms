#!/usr/bin/env python3
"""Regression tests for security-sensitive OpenAPI contract invariants."""

from __future__ import annotations

import copy
import unittest

from validate_contracts import (
    CALL_REALTIME_MESSAGES,
    CONTRACTS,
    load_yaml,
    validate_call_contract,
    validate_call_realtime_contract,
    validate_guest_contract,
)


class ContractValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.openapi = load_yaml(CONTRACTS / "openapi" / "openapi.yaml")

    def test_current_guest_and_call_contracts_pass(self) -> None:
        validate_call_contract(self.openapi)
        validate_guest_contract(self.openapi)

    def test_guest_link_creation_requires_runtime_conversion_metadata(self) -> None:
        document = copy.deepcopy(self.openapi)
        data = document["components"]["schemas"]["GuestLinkCreationResponse"][
            "properties"
        ]["data"]
        data["required"].remove("conversion_enabled")
        data["properties"].pop("conversion_enabled")

        with self.assertRaisesRegex(ValueError, "GuestLinkCreationResponse"):
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
        request = document["components"]["schemas"]["ConvertGuestAccountRequest"]
        request["required"].remove("verification_code")

        with self.assertRaisesRegex(ValueError, "ConvertGuestAccountRequest"):
            validate_guest_contract(document)

        document = copy.deepcopy(self.openapi)
        verification_code = document["components"]["schemas"][
            "ConvertGuestAccountRequest"
        ]["properties"]["verification_code"]
        verification_code.pop("writeOnly")
        verification_code["readOnly"] = True

        with self.assertRaisesRegex(ValueError, "ConvertGuestAccountRequest"):
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


if __name__ == "__main__":
    unittest.main()
