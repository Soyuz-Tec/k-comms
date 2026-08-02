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
    validate_instant_room_contract,
    validate_instant_room_realtime_contract,
    validate_whiteboard_contract,
    validate_whiteboard_realtime_contract,
)


class ContractValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.openapi = load_yaml(CONTRACTS / "openapi" / "openapi.yaml")

    def test_current_guest_call_and_instant_room_contracts_pass(self) -> None:
        validate_call_contract(self.openapi)
        validate_guest_contract(self.openapi)
        validate_instant_room_contract(self.openapi)
        validate_whiteboard_contract(self.openapi)

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
        ]["enum"].append("image")

        with self.assertRaisesRegex(ValueError, "safe SDK subset"):
            validate_whiteboard_contract(openapi)

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


if __name__ == "__main__":
    unittest.main()
