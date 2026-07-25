#!/usr/bin/env python3
"""Validate canonical API contracts and their documentation mirrors."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import yaml
from jsonschema.validators import validator_for
from openapi_spec_validator import validate as validate_openapi


ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "contracts"

MESSAGE_EVENT_FIELDS = {
    "id",
    "tenant_id",
    "conversation_id",
    "conversation_sequence",
    "sender_user_id",
    "sender_device_id",
    "client_message_id",
    "reply_to_message_id",
    "thread_root_message_id",
    "thread_reply_count",
    "mentioned_user_ids",
    "body",
    "metadata",
    "status",
    "edited_at",
    "deleted_at",
    "inserted_at",
    "attachments",
    "reactions",
}

CALL_LIFECYCLE_EVENT_FIELDS = {
    "id",
    "conversation_id",
    "media_kind",
    "started_by_user_id",
    "status",
    "started_at",
    "expires_at",
    "ended_by_user_id",
    "ended_at",
    "end_reason",
}

CALL_REALTIME_MESSAGES = {
    "callStarted": ("CallStarted", "call.started.v1", "CallStartedPayload"),
    "callEnded": ("CallEnded", "call.ended.v1", "CallEndedPayload"),
    "audioCallStarted": (
        "AudioCallStarted",
        "audio_call.started.v1",
        "AudioCallStartedPayload",
    ),
    "audioCallEnded": (
        "AudioCallEnded",
        "audio_call.ended.v1",
        "AudioCallEndedPayload",
    ),
}

REQUIRED_MUTATION_BODIES = {
    ("/api/v1/guest-links/preview", "post"),
    ("/api/v1/guest-sessions", "post"),
    ("/api/v1/guest/sessions/refresh", "post"),
    ("/api/v1/guest/conversation/messages", "post"),
    ("/api/v1/guest/conversation/read-cursor", "put"),
    ("/api/v1/guest/conversation/calls", "post"),
    ("/api/v1/guest/account", "post"),
    ("/api/v1/me/profile", "patch"),
    ("/api/v1/conversations/{conversationId}/guest-links", "post"),
    ("/api/v1/me/password", "put"),
    ("/api/v1/conversations/{conversationId}", "patch"),
    ("/api/v1/conversations/{conversationId}/members/{userId}", "patch"),
    ("/api/v1/conversations/{conversationId}/members/{userId}", "delete"),
    ("/api/v1/conversations/{conversationId}/archive", "post"),
    ("/api/v1/conversations/{conversationId}/calls", "post"),
    ("/api/v1/moderation/cases", "post"),
    ("/api/v1/moderation/cases/{caseId}/actions", "post"),
    ("/api/v1/admin/users/{userId}", "patch"),
    ("/api/v1/admin/users/{userId}/sessions/{sessionId}", "delete"),
    ("/api/v1/admin/invitations", "post"),
    ("/api/v1/admin/invitations/{invitationId}/revoke", "post"),
    ("/api/v1/admin/retention-policies", "post"),
    ("/api/v1/admin/retention-policies/{policyId}", "patch"),
    ("/api/v1/admin/legal-holds", "post"),
    ("/api/v1/admin/legal-holds/{holdId}/release", "post"),
    ("/api/v1/admin/deletion-requests", "post"),
    ("/api/v1/admin/deletion-requests/{requestId}", "patch"),
    ("/api/v1/admin/webhooks", "post"),
    ("/api/v1/admin/webhooks/{endpointId}", "patch"),
    ("/api/v1/ops/retry", "post"),
}

REQUIRED_OPERATION_STATUSES = {
    ("/api/v1/guest-links/preview", "post"): {"200", "404", "429"},
    ("/api/v1/guest-sessions", "post"): {"201", "404", "409", "422", "429"},
    ("/api/v1/guest/sessions/refresh", "post"): {"200", "401"},
    ("/api/v1/guest/conversation/messages", "post"): {
        "201",
        "401",
        "403",
        "422",
    },
    ("/api/v1/guest/conversation/read-cursor", "put"): {"200", "401", "403"},
    ("/api/v1/guest/conversation/calls", "post"): {
        "200",
        "201",
        "401",
        "403",
        "404",
        "409",
        "422",
        "503",
    },
    ("/api/v1/guest/account", "post"): {"200", "401", "403", "409", "422"},
    ("/api/v1/conversations/{conversationId}/guest-links", "post"): {
        "201",
        "403",
        "404",
        "409",
        "422",
    },
    (
        "/api/v1/conversations/{conversationId}/guest-links/{guestLinkId}",
        "delete",
    ): {"200", "403", "404"},
    ("/api/v1/me/profile", "patch"): {"200", "401", "404", "409", "422"},
    ("/api/v1/conversations/{conversationId}", "patch"): {
        "200",
        "403",
        "404",
        "409",
        "422",
        "428",
    },
    ("/api/v1/conversations/{conversationId}/members/{userId}", "patch"): {
        "200",
        "403",
        "404",
        "409",
        "422",
        "428",
    },
    ("/api/v1/conversations/{conversationId}/members/{userId}", "delete"): {
        "204",
        "403",
        "404",
        "409",
        "428",
    },
    ("/api/v1/conversations/{conversationId}/archive", "post"): {
        "200",
        "403",
        "404",
        "409",
        "428",
    },
    ("/api/v1/conversations/{conversationId}/calls", "post"): {
        "200",
        "201",
        "403",
        "404",
        "409",
        "422",
        "503",
    },
    ("/api/v1/conversations/{conversationId}/calls/{callId}/join", "post"): {
        "200",
        "403",
        "404",
        "409",
        "503",
    },
    ("/api/v1/conversations/{conversationId}/calls/{callId}/end", "post"): {
        "200",
        "403",
        "404",
    },
    (
        "/api/v1/conversations/{conversationId}/messages/{messageId}/reactions/{emoji}",
        "delete",
    ): {"204", "403", "404"},
    ("/api/v1/moderation/cases", "post"): {"200", "201", "403", "422"},
    ("/api/v1/moderation/cases/{caseId}/actions", "post"): {
        "200",
        "403",
        "404",
        "409",
        "422",
        "428",
    },
    ("/api/v1/admin/invitations", "post"): {"200", "201", "403", "422"},
    ("/api/v1/admin/retention-policies", "post"): {"200", "201", "403", "422"},
    ("/api/v1/admin/legal-holds", "post"): {"200", "201", "403", "409", "422"},
    ("/api/v1/admin/deletion-requests", "post"): {"200", "201", "403", "422"},
    ("/api/v1/admin/webhooks", "post"): {"201", "403", "422", "503"},
    ("/api/v1/ops/retry", "post"): {"202", "403", "404", "409", "422"},
}


def load_yaml(path: Path) -> dict[str, Any]:
    value = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a mapping")
    return value


def validate_refs(value: Any, source: Path) -> None:
    if isinstance(value, dict):
        ref = value.get("$ref")
        if isinstance(ref, str) and not ref.startswith("#/"):
            target_text = ref.split("#", 1)[0]
            target = (source.parent / target_text).resolve()
            if not target.is_file():
                raise ValueError(f"unresolved reference {ref!r} in {source}")
        for child in value.values():
            validate_refs(child, source)
    elif isinstance(value, list):
        for child in value:
            validate_refs(child, source)


def validate_mutation_contracts(openapi: dict[str, Any]) -> None:
    paths = openapi.get("paths", {})

    for path, method in sorted(REQUIRED_MUTATION_BODIES):
        operation = paths.get(path, {}).get(method)
        if not isinstance(operation, dict):
            raise ValueError(f"missing mutation operation: {method.upper()} {path}")
        request_body = operation.get("requestBody")
        if (
            not isinstance(request_body, dict)
            or request_body.get("required") is not True
        ):
            raise ValueError(
                f"mutation requires a documented request body: {method.upper()} {path}"
            )

    for (path, method), expected_statuses in REQUIRED_OPERATION_STATUSES.items():
        operation = paths.get(path, {}).get(method)
        if not isinstance(operation, dict):
            raise ValueError(f"missing mutation operation: {method.upper()} {path}")
        actual_statuses = set(operation.get("responses", {}))
        missing = expected_statuses - actual_statuses
        if missing:
            raise ValueError(
                f"mutation response statuses are incomplete for {method.upper()} {path}: "
                f"missing {sorted(missing)}"
            )


def validate_message_contract(schema: dict[str, Any], openapi: dict[str, Any]) -> None:
    schema_fields = set(schema.get("properties", {}))
    schema_required = set(schema.get("required", []))
    if (
        schema_fields != MESSAGE_EVENT_FIELDS
        or schema_required != MESSAGE_EVENT_FIELDS
        or schema.get("additionalProperties") is not False
    ):
        raise ValueError(
            "message-created.v1 must exactly describe the presenter event fields"
        )

    openapi_message = (
        openapi.get("components", {}).get("schemas", {}).get("Message", {})
    )
    openapi_fields = set(openapi_message.get("properties", {}))
    openapi_required = set(openapi_message.get("required", []))
    if (
        openapi_fields != MESSAGE_EVENT_FIELDS
        or openapi_required != MESSAGE_EVENT_FIELDS
        or openapi_message.get("additionalProperties") is not False
    ):
        raise ValueError("OpenAPI Message must stay aligned with message-created.v1")


def validate_call_contract(openapi: dict[str, Any]) -> None:
    paths = openapi.get("paths", {})
    schemas = openapi.get("components", {}).get("schemas", {})

    canonical = {
        "/api/v1/conversations/{conversationId}/call": "getActiveCall",
        "/api/v1/conversations/{conversationId}/calls": "startCall",
        "/api/v1/conversations/{conversationId}/calls/{callId}/join": "joinCall",
        "/api/v1/conversations/{conversationId}/calls/{callId}/end": "endCall",
    }
    for path, operation_id in canonical.items():
        if path not in paths:
            raise ValueError(f"OpenAPI is missing canonical call route {path}")
        operations = [
            operation
            for method, operation in paths[path].items()
            if method in {"get", "post", "put", "patch", "delete"}
        ]
        if len(operations) != 1 or operations[0].get("operationId") != operation_id:
            raise ValueError(
                f"OpenAPI canonical call route {path} has the wrong operation"
            )

    for path in (
        "/api/v1/conversations/{conversationId}/audio-call",
        "/api/v1/conversations/{conversationId}/audio-calls",
        "/api/v1/conversations/{conversationId}/audio-calls/{callId}/join",
        "/api/v1/conversations/{conversationId}/audio-calls/{callId}/end",
    ):
        if path not in paths:
            raise ValueError(f"OpenAPI is missing audio compatibility route {path}")
        operation = paths[path].get("get") or paths[path].get("post")
        if not isinstance(operation, dict) or operation.get("deprecated") is not True:
            raise ValueError(
                f"OpenAPI audio compatibility route {path} must be deprecated"
            )

    start_request = schemas.get("StartCallRequest", {})
    if (
        set(start_request.get("required", [])) != {"media_kind"}
        or start_request.get("additionalProperties") is not False
        or set(
            start_request.get("properties", {}).get("media_kind", {}).get("enum", [])
        )
        != {"audio", "video"}
    ):
        raise ValueError("StartCallRequest must require exactly audio|video media_kind")

    call_schema = schemas.get("AudioCall", {})
    if "media_kind" not in set(call_schema.get("required", [])) or set(
        call_schema.get("properties", {}).get("media_kind", {}).get("enum", [])
    ) != {"audio", "video"}:
        raise ValueError(
            "AudioCall aggregate contract must require audio|video media_kind"
        )

    credential_contracts = {
        "AudioCallCredential": 60,
        "GuestAudioCallCredential": 1,
    }
    for schema_name, minimum_ttl in credential_contracts.items():
        credential = schemas.get(schema_name, {})
        properties = credential.get("properties", {})
        participant_token = properties.get("participant_token", {})
        expires_in = properties.get("expires_in", {})
        if (
            credential.get("additionalProperties") is not False
            or set(credential.get("required", []))
            != {"server_url", "participant_token", "expires_in"}
            or participant_token.get("readOnly") is not True
            or "writeOnly" in participant_token
            or expires_in.get("minimum") != minimum_ttl
            or expires_in.get("maximum") != 300
        ):
            raise ValueError(
                f"{schema_name} must expose a read-only participant token and "
                f"bound its response TTL to {minimum_ttl}..300 seconds"
            )

    response_refs = {
        "AudioCallCredentialResponse": "#/components/schemas/AudioCallCredential",
        "GuestAudioCallCredentialResponse": "#/components/schemas/GuestAudioCallCredential",
    }
    for schema_name, credential_ref in response_refs.items():
        response = schemas.get(schema_name, {})
        if (
            response.get("additionalProperties") is not False
            or set(response.get("required", [])) != {"data", "credential"}
            or response.get("properties", {}).get("credential", {}).get("$ref")
            != credential_ref
        ):
            raise ValueError(
                f"{schema_name} must reference its matching call credential schema"
            )

    expected_call_response_refs = {
        (
            "/api/v1/conversations/{conversationId}/calls",
            "post",
            "200",
        ): "#/components/schemas/AudioCallCredentialResponse",
        (
            "/api/v1/conversations/{conversationId}/calls",
            "post",
            "201",
        ): "#/components/schemas/AudioCallCredentialResponse",
        (
            "/api/v1/conversations/{conversationId}/calls/{callId}/join",
            "post",
            "200",
        ): "#/components/schemas/AudioCallCredentialResponse",
        (
            "/api/v1/guest/conversation/calls",
            "post",
            "200",
        ): "#/components/schemas/GuestAudioCallCredentialResponse",
        (
            "/api/v1/guest/conversation/calls",
            "post",
            "201",
        ): "#/components/schemas/GuestAudioCallCredentialResponse",
        (
            "/api/v1/guest/conversation/calls/{callId}/join",
            "post",
            "200",
        ): "#/components/schemas/GuestAudioCallCredentialResponse",
    }
    for (path, method, status), expected_ref in expected_call_response_refs.items():
        observed_ref = (
            paths.get(path, {})
            .get(method, {})
            .get("responses", {})
            .get(status, {})
            .get("content", {})
            .get("application/json", {})
            .get("schema", {})
            .get("$ref")
        )
        if observed_ref != expected_ref:
            raise ValueError(
                f"{method.upper()} {path} response {status} must use {expected_ref}"
            )

    for schema_name in (
        "UserCapabilities",
        "TenantSettings",
        "UpdateTenantSettingsRequest",
    ):
        properties = schemas.get(schema_name, {}).get("properties", {})
        if properties.get("allow_audio_calls") != {"type": "boolean"} or properties.get(
            "allow_video_calls"
        ) != {"type": "boolean"}:
            raise ValueError(
                f"{schema_name} must expose independent audio and video policy booleans"
            )

    capabilities = (
        schemas.get("StatusResponse", {}).get("properties", {}).get("capabilities", {})
    )
    required_capabilities = set(capabilities.get("required", []))
    status_properties = capabilities.get("properties", {})

    if any(
        capability not in required_capabilities
        or status_properties.get(capability, {}).get("type") != "boolean"
        for capability in ("audio_calls", "video_calls", "guest_links")
    ):
        raise ValueError(
            "StatusResponse must require public boolean audio_calls, video_calls, "
            "and guest_links capabilities"
        )


def validate_guest_contract(openapi: dict[str, Any]) -> None:
    paths = openapi.get("paths", {})
    schemas = openapi.get("components", {}).get("schemas", {})
    security_schemes = openapi.get("components", {}).get("securitySchemes", {})

    operations = {
        ("/api/v1/guest-links/preview", "post"): "previewGuestLink",
        ("/api/v1/guest-sessions", "post"): "createGuestSession",
        ("/api/v1/guest/sessions/refresh", "post"): "refreshGuestSession",
        ("/api/v1/guest/sessions/current", "delete"): "revokeCurrentGuestSession",
        ("/api/v1/guest/conversation", "get"): "getGuestConversation",
        (
            "/api/v1/guest/conversation/members",
            "get",
        ): "listGuestConversationMembers",
        (
            "/api/v1/guest/conversation/messages",
            "get",
        ): "listGuestConversationMessages",
        (
            "/api/v1/guest/conversation/messages",
            "post",
        ): "createGuestConversationMessage",
        (
            "/api/v1/guest/conversation/read-cursor",
            "put",
        ): "updateGuestConversationReadCursor",
        ("/api/v1/guest/socket-tickets", "post"): "createGuestSocketTicket",
        ("/api/v1/guest/conversation/call", "get"): "getGuestActiveCall",
        ("/api/v1/guest/conversation/calls", "post"): "startGuestCall",
        (
            "/api/v1/guest/conversation/calls/{callId}/join",
            "post",
        ): "joinGuestCall",
        (
            "/api/v1/guest/conversation/calls/{callId}/end",
            "post",
        ): "endGuestCall",
        ("/api/v1/guest/account", "post"): "convertGuestAccount",
        (
            "/api/v1/conversations/{conversationId}/guest-links",
            "get",
        ): "listConversationGuestLinks",
        (
            "/api/v1/conversations/{conversationId}/guest-links",
            "post",
        ): "createConversationGuestLink",
        (
            "/api/v1/conversations/{conversationId}/guest-links/{guestLinkId}",
            "delete",
        ): "revokeConversationGuestLink",
    }
    for (path, method), operation_id in operations.items():
        operation = paths.get(path, {}).get(method)
        if not isinstance(operation, dict):
            raise ValueError(f"OpenAPI is missing guest route {method.upper()} {path}")
        if operation.get("operationId") != operation_id:
            raise ValueError(
                f"OpenAPI guest route {method.upper()} {path} has the wrong operationId"
            )

    public_operations = (
        paths["/api/v1/guest-links/preview"]["post"],
        paths["/api/v1/guest-sessions"]["post"],
        paths["/api/v1/guest/sessions/refresh"]["post"],
    )
    if any(operation.get("security") for operation in public_operations):
        raise ValueError(
            "guest preview, admission, and refresh must not accept bearer auth"
        )

    for method in ("get", "post"):
        host_operation = paths["/api/v1/conversations/{conversationId}/guest-links"][
            method
        ]
        if host_operation.get("security") != [{"bearerAuth": []}]:
            raise ValueError(
                "guest-link host operations must require human bearer auth"
            )
    revoke_operation = paths[
        "/api/v1/conversations/{conversationId}/guest-links/{guestLinkId}"
    ]["delete"]
    if revoke_operation.get("security") != [{"bearerAuth": []}]:
        raise ValueError("guest-link revocation must require human bearer auth")

    guest_scoped_paths = {
        path
        for path in paths
        if path.startswith("/api/v1/guest/")
        and path != "/api/v1/guest/sessions/refresh"
    }
    for path in guest_scoped_paths:
        for method, operation in paths[path].items():
            if method not in {"get", "post", "put", "patch", "delete"}:
                continue
            if operation.get("security") != [{"guestBearerAuth": []}]:
                raise ValueError(
                    f"guest-scoped route must use only guestBearerAuth: "
                    f"{method.upper()} {path}"
                )

    expected_guest_scheme = {
        "type": "http",
        "scheme": "bearer",
        "bearerFormat": "K-Comms guest access token",
        "description": (
            "Conversation-scoped guest credential; rejected by human, admin, "
            "operations, service, and normal refresh routes."
        ),
    }
    if security_schemes.get("guestBearerAuth") != expected_guest_scheme:
        raise ValueError("guestBearerAuth must remain a separate scoped bearer purpose")

    create_link = schemas.get("CreateGuestLinkRequest", {})
    create_properties = create_link.get("properties", {})
    if (
        create_link.get("additionalProperties") is not False
        or create_properties.get("expires_in_seconds", {}).get("minimum") != 900
        or create_properties.get("expires_in_seconds", {}).get("maximum") != 86400
        or create_properties.get("max_uses", {}).get("minimum") != 1
        or create_properties.get("max_uses", {}).get("maximum") != 25
        or create_properties.get("conversion_email", {}).get("type")
        != ["string", "null"]
        or create_properties.get("conversion_email", {}).get("format") != "email"
        or create_properties.get("conversion_email", {}).get("maxLength") != 320
        or create_properties.get("conversion_email", {}).get("writeOnly") is not True
    ):
        raise ValueError(
            "CreateGuestLinkRequest must bound lifetime to 900..86400 seconds "
            "and uses to 1..25, with an optional write-only conversion email"
        )

    token_pattern = (
        r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
        r"[89ab][0-9a-f]{3}-[0-9a-f]{12}\.[A-Za-z0-9_-]{43}$"
    )
    for schema_name in (
        "GuestLinkTokenRequest",
        "CreateGuestSessionRequest",
    ):
        token = schemas.get(schema_name, {}).get("properties", {}).get("token", {})
        if (
            token.get("minLength") != 80
            or token.get("maxLength") != 80
            or token.get("pattern") != token_pattern
            or token.get("writeOnly") is not True
        ):
            raise ValueError(
                f"{schema_name}.token must be the exact write-only guest-link format"
            )

    guest_link = schemas.get("GuestLink", {})
    guest_link_properties = guest_link.get("properties", {})
    if {
        "token",
        "token_hash",
        "share_url",
        "conversion_verification_code",
        "conversion_verification_digest",
    } & set(guest_link_properties):
        raise ValueError("GuestLink must never expose raw or persisted link secrets")
    if "updated_at" in guest_link_properties or "updated_at" in set(
        guest_link.get("required", [])
    ):
        raise ValueError(
            "GuestLink must expose only the stable projection and omit updated_at"
        )
    guest_link_required = set(guest_link.get("required", []))
    if (
        not {"conversion_enabled", "email_hint"}.issubset(guest_link_required)
        or guest_link_properties.get("conversion_enabled") != {"type": "boolean"}
        or guest_link_properties.get("email_hint", {}).get("type") != ["string", "null"]
    ):
        raise ValueError(
            "GuestLink must expose required conversion_enabled and masked email_hint fields"
        )

    creation = schemas.get("GuestLinkCreationResponse", {})
    creation_properties = creation.get("properties", {})
    creation_data = creation_properties.get("data", {})
    creation_data_required = set(creation_data.get("required", []))
    creation_data_properties = creation_data.get("properties", {})
    creation_token = creation_properties.get("token", {})
    creation_share_url = creation_properties.get("share_url", {})
    creation_verification_code = creation_properties.get(
        "conversion_verification_code", {}
    )
    creation_data_share_url = creation_data_properties.get("share_url", {})
    verification_code_pattern = r"^[A-Za-z0-9_-]{43}$"
    if (
        creation.get("additionalProperties") is not False
        or creation_data.get("additionalProperties") is not False
        or not {"conversion_enabled", "email_hint"}.issubset(creation_data_required)
        or creation_data_properties.get("conversion_enabled") != {"type": "boolean"}
        or creation_data_properties.get("email_hint", {}).get("type")
        != ["string", "null"]
        or creation_token.get("readOnly") is not True
        or "writeOnly" in creation_token
        or creation_token.get("pattern") != token_pattern
        or creation_share_url.get("readOnly") is not True
        or "writeOnly" in creation_share_url
        or creation_share_url.get("pattern") != "/join#guest="
        or creation_verification_code.get("readOnly") is not True
        or "writeOnly" in creation_verification_code
        or creation_verification_code.get("minLength") != 43
        or creation_verification_code.get("maxLength") != 43
        or creation_verification_code.get("pattern") != verification_code_pattern
        or "conversion_verification_code" in creation_data_properties
        or creation_data_share_url.get("readOnly") is not True
        or "writeOnly" in creation_data_share_url
        or creation_data_share_url.get("pattern") != "/join#guest="
    ):
        raise ValueError(
            "GuestLinkCreationResponse must be closed, include conversion metadata, "
            "and expose its read-only raw token, conversion verification code, "
            "and /join fragment URL once without putting conversion verification "
            "into the shared data projection"
        )

    conversion_request = schemas.get("ConvertGuestAccountRequest", {})
    conversion_properties = conversion_request.get("properties", {})
    conversion_verification_code = conversion_properties.get("verification_code", {})
    conversion_password = conversion_properties.get("password", {})
    if (
        conversion_request.get("additionalProperties") is not False
        or set(conversion_request.get("required", []))
        != {"email", "verification_code", "password"}
        or conversion_verification_code.get("minLength") != 43
        or conversion_verification_code.get("maxLength") != 43
        or conversion_verification_code.get("pattern") != verification_code_pattern
        or conversion_verification_code.get("writeOnly") is not True
        or "readOnly" in conversion_verification_code
        or conversion_password.get("writeOnly") is not True
        or "readOnly" in conversion_password
    ):
        raise ValueError(
            "ConvertGuestAccountRequest must require an exact write-only "
            "verification_code and write-only password"
        )

    preview_response = schemas.get("GuestLinkPreviewResponse", {})
    preview_data = preview_response.get("properties", {}).get("data", {})
    preview_fields = {
        "room_title",
        "expires_at",
        "conversion_enabled",
        "email_hint",
    }
    preview_properties = preview_data.get("properties", {})
    if (
        preview_response.get("additionalProperties") is not False
        or set(preview_response.get("required", [])) != {"data"}
        or set(preview_response.get("properties", {})) != {"data"}
        or preview_data.get("additionalProperties") is not False
        or set(preview_data.get("required", [])) != preview_fields
        or set(preview_properties) != preview_fields
        or preview_properties.get("room_title", {}).get("type") != "string"
        or preview_properties.get("room_title", {}).get("minLength") != 1
        or preview_properties.get("room_title", {}).get("maxLength") != 160
        or preview_properties.get("expires_at")
        != {"type": "string", "format": "date-time"}
        or preview_properties.get("conversion_enabled") != {"type": "boolean"}
        or preview_properties.get("email_hint", {}).get("type")
        != ["string", "null"]
        or preview_properties.get("email_hint", {}).get("maxLength") != 320
    ):
        raise ValueError(
            "GuestLinkPreviewResponse must be a closed minimal pre-admission "
            "projection containing only room_title, expires_at, "
            "conversion_enabled, and masked email_hint"
        )

    guest_session = schemas.get("GuestSessionResponse", {})
    for property_name in ("access_token", "refresh_token"):
        credential = guest_session.get("properties", {}).get(property_name, {})
        if credential.get("readOnly") is not True or "writeOnly" in credential:
            raise ValueError(
                f"GuestSessionResponse.{property_name} must be a read-only response secret"
            )

    token_response = schemas.get("TokenResponse", {})
    expected_token_fields = {
        "access_token",
        "refresh_token",
        "token_type",
        "expires_in",
        "tenant",
        "user",
        "device",
    }
    if (
        set(token_response.get("required", [])) != expected_token_fields
        or set(token_response.get("properties", {})) != expected_token_fields
    ):
        raise ValueError(
            "TokenResponse must match the runtime authentication payload; "
            "capabilities are obtained from GET /api/v1/me"
        )
    for property_name in ("access_token", "refresh_token"):
        credential = token_response.get("properties", {}).get(property_name, {})
        if credential.get("readOnly") is not True or "writeOnly" in credential:
            raise ValueError(
                f"TokenResponse.{property_name} must be a read-only response secret"
            )

    conversion_auth_ref = (
        schemas.get("GuestAccountConversionResponse", {})
        .get("properties", {})
        .get("authentication", {})
        .get("$ref")
    )
    if conversion_auth_ref != "#/components/schemas/TokenResponse":
        raise ValueError(
            "GuestAccountConversionResponse.authentication must use TokenResponse"
        )

    guest_socket_data = (
        schemas.get("SocketTicketResponse", {}).get("properties", {}).get("data", {})
    )
    guest_socket_ticket = guest_socket_data.get("properties", {}).get("ticket", {})
    guest_socket_ttl = guest_socket_data.get("properties", {}).get("expires_in", {})
    human_socket_ttl = (
        paths.get("/api/v1/socket-tickets", {})
        .get("post", {})
        .get("responses", {})
        .get("201", {})
        .get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("properties", {})
        .get("data", {})
        .get("properties", {})
        .get("expires_in", {})
    )
    if (
        guest_socket_ticket.get("readOnly") is not True
        or "writeOnly" in guest_socket_ticket
        or guest_socket_ttl.get("minimum") != 1
        or guest_socket_ttl.get("maximum") != 120
        or human_socket_ttl.get("minimum") != 10
        or human_socket_ttl.get("maximum") != 120
    ):
        raise ValueError(
            "guest socket tickets must allow a 1..120 second bounded lifetime "
            "without weakening the human 10..120 second ticket contract"
        )

    unavailable_code = (
        schemas.get("GuestLinkUnavailableError", {})
        .get("properties", {})
        .get("error", {})
        .get("properties", {})
        .get("code", {})
        .get("const")
    )
    if unavailable_code != "guest_link_unavailable":
        raise ValueError(
            "guest-link unavailable states must share one public error code"
        )
    for path in ("/api/v1/guest-links/preview", "/api/v1/guest-sessions"):
        responses = paths[path]["post"].get("responses", {})
        if "404" not in responses or {"400", "410"} & set(responses):
            raise ValueError(
                f"{path} must not distinguish malformed, expired, exhausted, "
                "revoked, and unknown links"
            )

    component_responses = openapi.get("components", {}).get("responses", {})
    expected_guest_response_refs = {
        (
            "/api/v1/guest/conversation/calls",
            "post",
            "403",
        ): "#/components/responses/GuestCallForbidden",
        (
            "/api/v1/guest/conversation/calls/{callId}/join",
            "post",
            "403",
        ): "#/components/responses/GuestCallForbidden",
        (
            "/api/v1/guest/account",
            "post",
            "403",
        ): "#/components/responses/GuestConversionForbidden",
        (
            "/api/v1/conversations/{conversationId}/guest-links",
            "post",
            "403",
        ): "#/components/responses/GuestLinkForbidden",
        (
            "/api/v1/conversations/{conversationId}/guest-links",
            "post",
            "422",
        ): "#/components/responses/GuestLinkUnprocessable",
    }
    for (path, method, status), expected_ref in expected_guest_response_refs.items():
        observed = (
            paths.get(path, {})
            .get(method, {})
            .get("responses", {})
            .get(status, {})
            .get("$ref")
        )
        if observed != expected_ref:
            raise ValueError(
                f"{method.upper()} {path} {status} must use {expected_ref}"
            )

    expected_examples = {
        ("GuestCallForbidden", "authorization_expired"): (
            "call_authorization_expired",
            "Call access is no longer authorized",
        ),
        ("GuestConversionForbidden", "conversion_not_enabled"): (
            "guest_account_conversion_not_enabled",
            "Account creation is not permitted for this guest link",
        ),
        ("GuestConversionForbidden", "conversion_email_mismatch"): (
            "guest_account_conversion_email_mismatch",
            "Account creation is not permitted for the supplied email",
        ),
        ("GuestConversionForbidden", "conversion_verification_failed"): (
            "guest_account_conversion_verification_failed",
            "Account conversion verification failed",
        ),
        ("GuestLinkForbidden", "conversion_forbidden"): (
            "guest_account_conversion_forbidden",
            "Account creation is not permitted for this guest link",
        ),
        ("GuestLinkUnprocessable", "conversion_requires_single_use"): (
            "guest_account_conversion_requires_single_use",
            "Account-enabled guest links must allow exactly one use",
        ),
        ("GuestLinkUnprocessable", "invalid_conversion_email"): (
            "invalid_guest_conversion_email",
            "The account conversion email is invalid",
        ),
    }
    for (
        response_name,
        example_name,
    ), (expected_code, expected_detail) in expected_examples.items():
        observed_error = (
            component_responses.get(response_name, {})
            .get("content", {})
            .get("application/json", {})
            .get("examples", {})
            .get(example_name, {})
            .get("value", {})
            .get("error", {})
        )
        if (
            observed_error.get("code") != expected_code
            or observed_error.get("detail") != expected_detail
        ):
            raise ValueError(
                f"{response_name}.{example_name} must document the exact "
                f"{expected_code} public response"
            )

    guest_member_user_properties = (
        schemas.get("GuestMember", {})
        .get("properties", {})
        .get("user", {})
        .get("properties", {})
    )
    if {"email", "external_subject", "platform_role"} & set(
        guest_member_user_properties
    ):
        raise ValueError("GuestMember must stay a sanitized conversation projection")

    guest_capabilities = schemas.get("GuestCapabilities", {})
    if (
        guest_capabilities.get("additionalProperties") is not False
        or set(guest_capabilities.get("required", []))
        != {
            "allow_audio_calls",
            "allow_video_calls",
            "conversion_enabled",
            "email_hint",
        }
        or set(guest_capabilities.get("properties", {}))
        != {
            "allow_audio_calls",
            "allow_video_calls",
            "conversion_enabled",
            "email_hint",
        }
        or guest_capabilities.get("properties", {}).get("conversion_enabled")
        != {"type": "boolean"}
        or guest_capabilities.get("properties", {}).get("email_hint", {}).get("type")
        != ["string", "null"]
    ):
        raise ValueError(
            "GuestCapabilities must expose tenant-authorized media booleans and "
            "fail-closed account-conversion metadata"
        )


def validate_guest_realtime_contract(asyncapi: dict[str, Any]) -> None:
    channels = asyncapi.get("channels", {})
    user_inbox_description = channels.get("userInbox", {}).get("description", "")
    if "Human-account-only" not in user_inbox_description:
        raise ValueError("AsyncAPI userInbox must explicitly reject guest sockets")

    conversation_description = (
        channels.get("conversation", {})
        .get("parameters", {})
        .get("conversationId", {})
        .get("description", "")
    )
    if "guest ticket must match its one admitted conversation" not in (
        conversation_description
    ):
        raise ValueError(
            "AsyncAPI conversation channel must bind guest tickets to one admission"
        )

    membership_source = (
        asyncapi.get("components", {})
        .get("messages", {})
        .get("MembershipChanged", {})
        .get("payload", {})
        .get("properties", {})
        .get("source", {})
        .get("enum", [])
    )
    if set(membership_source) != {"administrative", "self_service", "guest_link"}:
        raise ValueError(
            "AsyncAPI membership source must include only administrative, "
            "self_service, and guest_link"
        )


def validate_call_realtime_contract(asyncapi: dict[str, Any]) -> None:
    channels = asyncapi.get("channels", {})
    conversation_messages = channels.get("conversation", {}).get("messages", {})
    component_messages = asyncapi.get("components", {}).get("messages", {})

    for channel_key, (
        component_name,
        event_name,
        payload_name,
    ) in CALL_REALTIME_MESSAGES.items():
        expected_channel_ref = f"#/components/messages/{component_name}"
        if conversation_messages.get(channel_key) != {"$ref": expected_channel_ref}:
            raise ValueError(
                f"AsyncAPI conversation channel is missing call lifecycle message "
                f"{channel_key} -> {expected_channel_ref}"
            )

        component = component_messages.get(component_name, {})
        expected_payload_ref = f"#/components/schemas/{payload_name}"
        if component.get("name") != event_name or component.get("payload") != {
            "$ref": expected_payload_ref
        }:
            raise ValueError(
                f"AsyncAPI {component_name} must document {event_name} with "
                f"{expected_payload_ref}"
            )

    receive_messages = (
        asyncapi.get("operations", {})
        .get("receiveConversationEvent", {})
        .get("messages", [])
    )
    observed_receive_refs = {
        message.get("$ref")
        for message in receive_messages
        if isinstance(message, dict) and isinstance(message.get("$ref"), str)
    }
    expected_receive_refs = {
        f"#/channels/conversation/messages/{channel_key}"
        for channel_key in CALL_REALTIME_MESSAGES
    }
    missing_receive_refs = expected_receive_refs - observed_receive_refs
    if missing_receive_refs:
        raise ValueError(
            "AsyncAPI receiveConversationEvent omits call lifecycle messages: "
            f"{sorted(missing_receive_refs)}"
        )

    schemas = asyncapi.get("components", {}).get("schemas", {})
    expected_started_properties = {
        "id": {"type": "string", "format": "uuid"},
        "conversation_id": {"type": "string", "format": "uuid"},
        "media_kind": {"enum": ["audio", "video"]},
        "started_by_user_id": {"type": "string", "format": "uuid"},
        "status": {"const": "active"},
        "started_at": {"type": "string", "format": "date-time"},
        "expires_at": {"type": "string", "format": "date-time"},
        "ended_by_user_id": {"type": "null"},
        "ended_at": {"type": "null"},
        "end_reason": {"type": "null"},
    }
    expected_ended_properties = {
        "id": {"type": "string", "format": "uuid"},
        "conversation_id": {"type": "string", "format": "uuid"},
        "media_kind": {"enum": ["audio", "video"]},
        "started_by_user_id": {"type": "string", "format": "uuid"},
        "status": {"const": "ended"},
        "started_at": {"type": "string", "format": "date-time"},
        "expires_at": {"type": "string", "format": "date-time"},
        "ended_by_user_id": {"type": ["string", "null"], "format": "uuid"},
        "ended_at": {"type": "string", "format": "date-time"},
        "end_reason": {"type": "string", "minLength": 3, "maxLength": 120},
    }
    for schema_name, expected_properties in (
        ("CallStartedPayload", expected_started_properties),
        ("CallEndedPayload", expected_ended_properties),
    ):
        schema = schemas.get(schema_name, {})
        if (
            schema.get("type") != "object"
            or schema.get("additionalProperties") is not False
            or set(schema.get("required", [])) != CALL_LIFECYCLE_EVENT_FIELDS
            or schema.get("properties") != expected_properties
        ):
            raise ValueError(
                f"AsyncAPI {schema_name} must exactly match the emitted "
                "provider-free call lifecycle payload"
            )

    for alias_name, canonical_name in (
        ("AudioCallStartedPayload", "CallStartedPayload"),
        ("AudioCallEndedPayload", "CallEndedPayload"),
    ):
        expected_alias = {
            "allOf": [
                {"$ref": f"#/components/schemas/{canonical_name}"},
                {
                    "type": "object",
                    "properties": {"media_kind": {"const": "audio"}},
                },
            ]
        }
        if schemas.get(alias_name) != expected_alias:
            raise ValueError(
                f"AsyncAPI {alias_name} must remain an audio-only compatibility "
                f"alias of {canonical_name}"
            )


def main() -> None:
    schema_paths = sorted((CONTRACTS / "json-schema").glob("*.json"))
    if not schema_paths:
        raise ValueError("no JSON Schema contracts found")

    schemas: dict[str, dict[str, Any]] = {}
    for path in schema_paths:
        schema = json.loads(path.read_text(encoding="utf-8"))
        validator_for(schema).check_schema(schema)
        validate_refs(schema, path)
        schemas[path.name] = schema

    openapi_path = CONTRACTS / "openapi" / "openapi.yaml"
    openapi = load_yaml(openapi_path)
    validate_openapi(openapi)
    validate_refs(openapi, openapi_path)
    validate_mutation_contracts(openapi)
    validate_message_contract(schemas["message-created.v1.json"], openapi)
    validate_call_contract(openapi)
    validate_guest_contract(openapi)

    asyncapi_path = CONTRACTS / "asyncapi" / "asyncapi.yaml"
    asyncapi = load_yaml(asyncapi_path)
    if asyncapi.get("asyncapi") != "3.0.0":
        raise ValueError("AsyncAPI contract must use version 3.0.0")
    for required in ("info", "channels", "operations", "components"):
        if required not in asyncapi:
            raise ValueError(f"AsyncAPI contract is missing {required}")
    validate_refs(asyncapi, asyncapi_path)
    validate_guest_realtime_contract(asyncapi)
    validate_call_realtime_contract(asyncapi)

    mirrors = [
        (openapi_path, ROOT / "docs/04-interfaces/openapi/openapi.yaml"),
        (asyncapi_path, ROOT / "docs/04-interfaces/asyncapi/asyncapi.yaml"),
    ]
    for canonical, mirror in mirrors:
        if canonical.read_bytes() != mirror.read_bytes():
            raise ValueError(f"documentation mirror is stale: {mirror}")

    print(
        f"Contract validation passed: {len(schema_paths)} JSON Schemas, "
        "OpenAPI 3.1, AsyncAPI 3.0, and documentation mirrors"
    )


if __name__ == "__main__":
    main()
