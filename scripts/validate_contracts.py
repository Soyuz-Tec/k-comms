#!/usr/bin/env python3
"""Validate canonical API contracts and their documentation mirrors."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from urllib.parse import unquote

import yaml
from jsonschema.validators import validator_for
from openapi_spec_validator import validate as validate_openapi

from validate_phone_provisioning_contracts import validate_phone_provisioning_contract


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

WHITEBOARD_PATH = "/api/v1/conversations/{conversationId}/whiteboard/operations"
GUEST_WHITEBOARD_PATH = "/api/v1/guest/conversation/whiteboard/operations"
WHITEBOARD_ELEMENT_TYPES = {
    "rectangle",
    "diamond",
    "ellipse",
    "line",
    "arrow",
    "freedraw",
    "text",
    "frame",
    "image",
}

REQUIRED_MUTATION_BODIES = {
    ("/api/v1/instant-rooms", "post"),
    ("/api/v1/instant-rooms/preview", "post"),
    ("/api/v1/instant-room-sessions", "post"),
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
    (WHITEBOARD_PATH, "post"),
    (GUEST_WHITEBOARD_PATH, "post"),
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
    (GUEST_WHITEBOARD_PATH, "post"): {
        "200",
        "201",
        "401",
        "403",
        "409",
        "422",
        "429",
    },
    ("/api/v1/instant-rooms", "post"): {
        "200",
        "201",
        "401",
        "403",
        "409",
        "422",
        "429",
        "503",
    },
    ("/api/v1/instant-rooms/preview", "post"): {
        "200",
        "401",
        "403",
        "404",
        "429",
        "503",
    },
    ("/api/v1/instant-room-sessions", "post"): {
        "200",
        "201",
        "401",
        "403",
        "404",
        "409",
        "422",
        "429",
        "503",
    },
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
    """Check local JSON Pointers and retain external file-existence checks."""

    def validate_local_pointer(ref: str) -> None:
        try:
            pointer = unquote(ref[1:], errors="strict")
            if not pointer:
                return
            if not pointer.startswith("/"):
                raise ValueError("local reference must be a JSON Pointer")
            target = value
            for encoded_segment in pointer[1:].split("/"):
                for index, character in enumerate(encoded_segment):
                    if character == "~" and (
                        index + 1 == len(encoded_segment)
                        or encoded_segment[index + 1] not in "01"
                    ):
                        raise ValueError("invalid JSON Pointer escape")
                segment = encoded_segment.replace("~1", "/").replace("~0", "~")
                if isinstance(target, dict):
                    target = target[segment]
                elif isinstance(target, list):
                    if (
                        not segment.isascii()
                        or not segment.isdecimal()
                        or (len(segment) > 1 and segment.startswith("0"))
                    ):
                        raise ValueError("invalid JSON Pointer array index")
                    target = target[int(segment)]
                else:
                    raise ValueError("JSON Pointer traverses a scalar")
        except (KeyError, IndexError, ValueError) as error:
            raise ValueError(f"unresolved reference {ref!r} in {source}") from error

    # Walk the document itself, never dereference targets recursively. Recursive
    # schemas therefore terminate; identity tracking also handles YAML aliases.
    pending = [value]
    visited: set[int] = set()
    while pending:
        node = pending.pop()
        if not isinstance(node, (dict, list)) or id(node) in visited:
            continue
        visited.add(id(node))
        if isinstance(node, dict):
            ref = node.get("$ref")
            if isinstance(ref, str):
                if ref.startswith("#"):
                    validate_local_pointer(ref)
                else:
                    target_text = ref.split("#", 1)[0]
                    target = (source.parent / target_text).resolve()
                    if not target.is_file():
                        raise ValueError(f"unresolved reference {ref!r} in {source}")
            pending.extend(node.values())
        else:
            pending.extend(node)


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


def validate_telephony_contract(openapi: dict[str, Any]) -> None:
    """Keep individual phone admission separate from room calls and provider auth."""

    paths = openapi.get("paths", {})
    schemas = openapi.get("components", {}).get("schemas", {})
    authenticated_operations = {
        ("/api/v1/telephony/config", "get"),
        ("/api/v1/admin/telephony", "get"),
        ("/api/v1/admin/telephony", "put"),
        ("/api/v1/telephony/calls", "get"),
        ("/api/v1/telephony/calls", "post"),
        ("/api/v1/telephony/calls/{callId}", "get"),
        *{
            (f"/api/v1/telephony/calls/{{callId}}/{action}", "post")
            for action in ("answer", "reject", "end", "join")
        },
    }
    for path, method in sorted(authenticated_operations):
        operation = paths.get(path, {}).get(method, {})
        if operation.get("security") != [{"bearerAuth": []}]:
            raise ValueError(f"Telephony {method.upper()} {path} requires bearerAuth")

    webhook = paths.get("/api/v1/telephony/livekit/webhook", {}).get("post", {})
    if webhook.get("security") != [{"livekitWebhookAuth": []}]:
        raise ValueError("Telephony webhook requires separate livekitWebhookAuth")
    webhook_description = webhook.get("description", "")
    if not all(
        phrase in webhook_description
        for phrase in ("exact raw request bytes", "SHA-256", "Duplicate", "trunk")
    ):
        raise ValueError("Telephony webhook must document body-bound provider attribution")

    call = schemas.get("TelephonyCall", {})
    expected_call_fields = {
        "id", "direction", "status", "from_number", "to_number", "extension",
        "started_at", "answered_at", "ended_at", "connected_seconds",
        "can_answer", "can_join", "can_end", "active_on_this_device", "end_reason", "control_state",
    }
    if (
        call.get("additionalProperties") is not False
        or set(call.get("required", [])) != expected_call_fields
        or set(call.get("properties", {})) != expected_call_fields
    ):
        raise ValueError("TelephonyCall must expose only the frozen individual call projection")
    properties = call["properties"]
    if set(properties.get("control_state", {}).get("enum", [])) != {"connected", "held", "consulting", "transferred", "voicemail"}:
        raise ValueError("TelephonyCall must describe the bounded control state")
    if set(properties.get("status", {}).get("enum", [])) != {
        "ringing", "answered", "declined", "busy", "no_answer", "cancelled", "failed", "ended"
    }:
        raise ValueError("TelephonyCall must describe all individual call outcomes")
    if properties.get("connected_seconds", {}).get("minimum") != 0:
        raise ValueError("TelephonyCall connected duration must be nonnegative")

    start = schemas.get("StartTelephonyCallRequest", {})
    if (
        start.get("additionalProperties") is not False
        or set(start.get("required", [])) != {"destination", "idempotency_key"}
        or set(start.get("properties", {})) != {"destination", "idempotency_key"}
    ):
        raise ValueError("Telephony start must require a destination and idempotency key")

    credential = schemas.get("TelephonyCallCredentialResponse", {})
    if (
        credential.get("additionalProperties") is not False
        or set(credential.get("required", [])) != {"data", "credential"}
        or credential.get("properties", {}).get("credential", {}).get("$ref")
        != "#/components/schemas/TelephonyCredential"
    ):
        raise ValueError("Telephony admission must use a short-lived session-capped media credential")

    token = schemas.get("TelephonyCredential", {})
    if (
        token.get("additionalProperties") is not False
        or set(token.get("required", [])) != {"server_url", "participant_token", "expires_in", "ice_servers"}
        or token.get("properties", {}).get("expires_in", {}).get("minimum") != 1
        or token.get("properties", {}).get("expires_in", {}).get("maximum") != 300
        or token.get("properties", {}).get("participant_token", {}).get("readOnly") is not True
    ):
        raise ValueError("TelephonyCredential must retain bounded lifetime and read-only token")

    page = schemas.get("TelephonyCallPage", {})
    if (
        page.get("additionalProperties") is not False
        or set(page.get("required", [])) != {"data", "page"}
        or page.get("properties", {}).get("page", {}).get("$ref")
        != "#/components/schemas/CursorPage"
    ):
        raise ValueError("Telephony history must use bounded cursor pagination")


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
        for capability in (
            "audio_calls",
            "video_calls",
            "guest_links",
            "instant_rooms",
        )
    ):
        raise ValueError(
            "StatusResponse must require public boolean audio_calls, video_calls, "
            "guest_links, and instant_rooms capabilities"
        )


def validate_instant_room_contract(openapi: dict[str, Any]) -> None:
    paths = openapi.get("paths", {})
    schemas = openapi.get("components", {}).get("schemas", {})
    parameters = openapi.get("components", {}).get("parameters", {})
    responses = openapi.get("components", {}).get("responses", {})

    expected_operations = {
        ("/api/v1/instant-rooms", "post"): "createInstantRoom",
        ("/api/v1/instant-rooms/preview", "post"): "previewInstantRoom",
        ("/api/v1/instant-room-sessions", "post"): "joinInstantRoom",
    }
    for (path, method), operation_id in expected_operations.items():
        operation = paths.get(path, {}).get(method)
        if not isinstance(operation, dict):
            raise ValueError(
                f"OpenAPI is missing instant-room route {method.upper()} {path}"
            )
        if operation.get("operationId") != operation_id:
            raise ValueError(
                f"OpenAPI instant-room route {method.upper()} {path} "
                "has the wrong operationId"
            )
        if operation.get("security") != [{}, {"bearerAuth": []}]:
            raise ValueError(
                f"{method.upper()} {path} must accept only anonymous or human bearer"
            )

    for path in ("/api/v1/instant-rooms", "/api/v1/instant-room-sessions"):
        description = paths[path]["post"].get("description", "")
        if (
            "same-tenant human with workspace or conversation-only scope"
            not in description
            or "valid human from another tenant" not in description
        ):
            raise ValueError(
                f"POST {path} must preserve same-tenant conversation-only "
                "identity reuse and distinguish the cross-tenant guest fallback"
            )

    idempotency = parameters.get("RequiredIdempotencyKey", {})
    if (
        idempotency.get("name") != "Idempotency-Key"
        or idempotency.get("in") != "header"
        or idempotency.get("required") is not True
        or idempotency.get("schema")
        != {
            "type": "string",
            "minLength": 43,
            "maxLength": 43,
            "pattern": "^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$",
        }
        or "AES-GCM" not in idempotency.get("description", "")
    ):
        raise ValueError(
            "RequiredIdempotencyKey must be an exact 256-bit Base64URL header "
            "with bounded encrypted replay"
        )

    trusted_origin = parameters.get("RequiredTrustedOrigin", {})
    if (
        trusted_origin.get("name") != "Origin"
        or trusted_origin.get("in") != "header"
        or trusted_origin.get("required") is not True
        or trusted_origin.get("schema")
        != {"type": "string", "format": "uri", "minLength": 1, "maxLength": 2048}
        or "never selects the public tenant"
        not in trusted_origin.get("description", "")
    ):
        raise ValueError(
            "RequiredTrustedOrigin must be a bounded required Origin header "
            "that cannot select the public tenant"
        )

    expected_parameter_refs = {
        "/api/v1/instant-rooms": [
            "#/components/parameters/RequiredIdempotencyKey",
            "#/components/parameters/RequiredTrustedOrigin",
        ],
        "/api/v1/instant-rooms/preview": [
            "#/components/parameters/RequiredTrustedOrigin"
        ],
        "/api/v1/instant-room-sessions": [
            "#/components/parameters/RequiredIdempotencyKey",
            "#/components/parameters/RequiredTrustedOrigin",
        ],
    }
    for path, expected_refs in expected_parameter_refs.items():
        refs = [
            item.get("$ref")
            for item in paths[path]["post"].get("parameters", [])
            if isinstance(item, dict)
        ]
        if refs != expected_refs:
            raise ValueError(
                f"POST {path} must require exactly its trusted-origin and "
                "idempotency headers"
            )

    token_pattern = r"^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$"
    for schema_name in (
        "InstantRoomTokenRequest",
        "CreateInstantRoomSessionRequest",
    ):
        token = schemas.get(schema_name, {}).get("properties", {}).get("token", {})
        if (
            token.get("minLength") != 43
            or token.get("maxLength") != 43
            or token.get("pattern") != token_pattern
            or token.get("writeOnly") is not True
        ):
            raise ValueError(
                f"{schema_name}.token must be the exact write-only 256-bit format"
            )

    create_request = schemas.get("CreateInstantRoomRequest", {})
    device = schemas.get("InstantRoomDevice", {})
    if (
        create_request.get("additionalProperties") is not False
        or set(create_request.get("properties", {}))
        != {"title", "display_name", "device"}
        or "Anonymous creation requires a complete device"
        not in create_request.get("description", "")
        or "chosen display_name" not in create_request.get("description", "")
        or device.get("additionalProperties") is not False
        or set(device.get("required", [])) != {"name", "platform"}
        or set(device.get("properties", {})) != {"name", "platform"}
    ):
        raise ValueError(
            "instant-room create/device requests must remain closed, tenant-free, "
            "and explicit about anonymous device requirements"
        )

    join_request = schemas.get("CreateInstantRoomSessionRequest", {})
    if (
        set(join_request.get("required", [])) != {"token"}
        or "Anonymous join requires display_name and a complete device"
        not in join_request.get("description", "")
    ):
        raise ValueError(
            "CreateInstantRoomSessionRequest must document auth-dependent "
            "anonymous display and device requirements"
        )

    room = schemas.get("InstantRoom", {})
    room_properties = room.get("properties", {})
    expected_room_fields = {
        "id",
        "conversation_id",
        "owner_user_id",
        "owner_kind",
        "status",
        "participant_limit",
        "idle_since",
        "expires_at",
        "inserted_at",
        "updated_at",
    }
    if (
        room.get("additionalProperties") is not False
        or set(room.get("required", [])) != expected_room_fields
        or set(room_properties) != expected_room_fields
        or set(room_properties.get("owner_kind", {}).get("enum", []))
        != {"guest", "registered"}
        or set(room_properties.get("status", {}).get("enum", []))
        != {"active", "idle", "expired"}
        or room_properties.get("participant_limit", {}).get("maximum") != 25
        or room_properties.get("expires_at", {}).get("type")
        != ["string", "null"]
    ):
        raise ValueError(
            "InstantRoom must remain a closed bounded lifecycle projection"
        )

    preview = schemas.get("InstantRoomPreviewResponse", {})
    preview_data = preview.get("properties", {}).get("data", {})
    preview_fields = {"room_title", "status", "expires_at", "participant_limit"}
    if (
        preview.get("additionalProperties") is not False
        or set(preview.get("required", [])) != {"data"}
        or set(preview.get("properties", {})) != {"data"}
        or preview_data.get("additionalProperties") is not False
        or set(preview_data.get("required", [])) != preview_fields
        or set(preview_data.get("properties", {})) != preview_fields
        or preview_data.get("properties", {}).get("expires_at", {}).get("type")
        != ["string", "null"]
    ):
        raise ValueError(
            "InstantRoomPreviewResponse must remain a minimal public projection"
        )

    creation = schemas.get("InstantRoomCreationResponse", {})
    creation_required = set(creation.get("required", []))
    creation_properties = creation.get("properties", {})
    creation_token = creation_properties.get("token", {})
    creation_share_url = creation_properties.get("share_url", {})
    if (
        creation.get("additionalProperties") is not False
        or not {"room", "conversation", "token", "share_url", "replayed"}.issubset(
            creation_required
        )
        or creation_token.get("readOnly") is not True
        or "writeOnly" in creation_token
        or creation_token.get("pattern") != token_pattern
        or creation_share_url.get("readOnly") is not True
        or "writeOnly" in creation_share_url
        or creation_share_url.get("pattern") != "/join#guest="
    ):
        raise ValueError(
            "InstantRoomCreationResponse must expose the bounded replayable "
            "join secret and fragment URL as response-only fields"
        )

    for schema_name in ("InstantRoomCreationResponse", "InstantRoomSessionResponse"):
        response_schema = schemas.get(schema_name, {})
        for secret_name in ("access_token", "refresh_token"):
            secret = response_schema.get("properties", {}).get(secret_name, {})
            if secret.get("readOnly") is not True or "writeOnly" in secret:
                raise ValueError(
                    f"{schema_name}.{secret_name} must remain response-only"
                )

    expected_response_refs = {
        ("/api/v1/instant-rooms", "200"): (
            "#/components/schemas/InstantRoomCreationResponse"
        ),
        ("/api/v1/instant-rooms", "201"): (
            "#/components/schemas/InstantRoomCreationResponse"
        ),
        ("/api/v1/instant-room-sessions", "200"): (
            "#/components/schemas/InstantRoomSessionResponse"
        ),
        ("/api/v1/instant-room-sessions", "201"): (
            "#/components/schemas/InstantRoomSessionResponse"
        ),
    }
    for (path, status), expected_ref in expected_response_refs.items():
        observed_ref = (
            paths[path]["post"]
            .get("responses", {})
            .get(status, {})
            .get("content", {})
            .get("application/json", {})
            .get("schema", {})
            .get("$ref")
        )
        if observed_ref != expected_ref:
            raise ValueError(f"POST {path} {status} must use {expected_ref}")

    unavailable_properties = (
        schemas.get("InstantRoomUnavailableError", {})
        .get("properties", {})
        .get("error", {})
        .get("properties", {})
    )
    if (
        unavailable_properties.get("code", {}).get("const")
        != "instant_room_unavailable"
        or unavailable_properties.get("detail", {}).get("const")
        != "This instant communication room is unavailable"
    ):
        raise ValueError(
            "instant-room unavailable states must share one exact public error"
        )
    for path in (
        "/api/v1/instant-rooms/preview",
        "/api/v1/instant-room-sessions",
    ):
        operation_responses = paths[path]["post"].get("responses", {})
        unavailable_ref = (
            operation_responses.get("404", {})
            .get("content", {})
            .get("application/json", {})
            .get("schema", {})
            .get("$ref")
        )
        if (
            unavailable_ref
            != "#/components/schemas/InstantRoomUnavailableError"
            or {"400", "410"} & set(operation_responses)
        ):
            raise ValueError(
                f"{path} must not distinguish malformed, expired, exhausted, "
                "revoked, and unknown instant rooms"
            )

    service_unavailable_properties = (
        schemas.get("InstantRoomsUnavailableError", {})
        .get("properties", {})
        .get("error", {})
        .get("properties", {})
    )
    if (
        service_unavailable_properties.get("code", {}).get("const")
        != "instant_rooms_unavailable"
        or service_unavailable_properties.get("detail", {}).get("const")
        != "Instant communication rooms are unavailable"
    ):
        raise ValueError(
            "fail-closed instant-room service states must share one exact public error"
        )
    service_unavailable_paths = [
        *(operation_path for operation_path, _method in expected_operations),
        "/api/v1/guest/account",
    ]
    for operation_path in service_unavailable_paths:
        observed_ref = (
            paths[operation_path]["post"]
            .get("responses", {})
            .get("503", {})
            .get("content", {})
            .get("application/json", {})
            .get("schema", {})
            .get("$ref")
        )
        if observed_ref != "#/components/schemas/InstantRoomsUnavailableError":
            raise ValueError(
                f"POST {operation_path} 503 must use the fail-closed public "
                "instant-room error"
            )

    conflict = responses.get("InstantRoomConflict", {})
    conflict_examples = (
        conflict.get("content", {})
        .get("application/json", {})
        .get("examples", {})
    )
    expected_conflicts = {
        "fingerprint_conflict": (
            "idempotency_conflict",
            "The idempotency key was already used with a different request",
        ),
        "replay_expired": (
            "idempotency_replay_expired",
            "The idempotency replay window has expired",
        ),
    }
    for example_name, (expected_code, expected_detail) in expected_conflicts.items():
        error = (
            conflict_examples.get(example_name, {})
            .get("value", {})
            .get("error", {})
        )
        if (
            error.get("code") != expected_code
            or error.get("detail") != expected_detail
        ):
            raise ValueError(
                f"InstantRoomConflict.{example_name} must document the exact "
                f"{expected_code} runtime response"
            )
    for path in ("/api/v1/instant-rooms", "/api/v1/instant-room-sessions"):
        if (
            paths[path]["post"].get("responses", {}).get("409", {}).get("$ref")
            != "#/components/responses/InstantRoomConflict"
        ):
            raise ValueError(
                f"POST {path} 409 must use the instant-room idempotency contract"
            )

    rate_limited = responses.get("InstantRoomRateLimited", {})
    retry_after = rate_limited.get("headers", {}).get("Retry-After", {})
    if (
        retry_after.get("required") is not True
        or retry_after.get("schema") != {"type": "integer", "minimum": 1}
        or (
            rate_limited.get("content", {})
            .get("application/json", {})
            .get("schema", {})
            .get("$ref")
            != "#/components/schemas/InstantRoomRateLimitedError"
        )
    ):
        raise ValueError(
            "InstantRoomRateLimited must require a positive integer Retry-After "
            "header and the bounded rate-limit error body"
        )
    rate_error = (
        schemas.get("InstantRoomRateLimitedError", {})
        .get("properties", {})
        .get("error", {})
    )
    if (
        rate_error.get("additionalProperties") is not False
        or set(rate_error.get("required", []))
        != {"code", "detail", "retry_after"}
        or rate_error.get("properties", {}).get("code", {}).get("const")
        != "rate_limited"
        or rate_error.get("properties", {}).get("detail", {}).get("const")
        != "Too many requests"
        or rate_error.get("properties", {}).get("retry_after")
        != {"type": "integer", "minimum": 1}
    ):
        raise ValueError(
            "InstantRoomRateLimitedError must match the exact runtime body"
        )
    for operation_path, _method in expected_operations:
        if (
            paths[operation_path]["post"].get("responses", {}).get("415", {}).get(
                "$ref"
            )
            != "#/components/responses/Error"
        ):
            raise ValueError(
                f"POST {operation_path} must document unsupported application/json"
            )

    rate_limited_paths = [
        *(operation_path for operation_path, _method in expected_operations),
        "/api/v1/guest/account",
        "/api/v1/guest/conversation/messages",
    ]
    for operation_path in rate_limited_paths:
        if (
            paths[operation_path]["post"].get("responses", {}).get("429", {}).get(
                "$ref"
            )
            != "#/components/responses/InstantRoomRateLimited"
        ):
            raise ValueError(
                f"POST {operation_path} 429 must expose the Retry-After contract"
            )

    instant_status = (
        schemas.get("StatusResponse", {})
        .get("properties", {})
        .get("capabilities", {})
        .get("properties", {})
        .get("instant_rooms", {})
    )
    if (
        instant_status.get("type") != "boolean"
        or "Production still requires verification" not in instant_status.get(
            "description", ""
        )
    ):
        raise ValueError(
            "instant_rooms status must document its fail-closed production gate"
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

    logout_description = (
        paths.get("/api/v1/guest/sessions/current", {})
        .get("delete", {})
        .get("responses", {})
        .get("204", {})
        .get("description", "")
    )
    if not all(
        phrase in logout_description
        for phrase in (
            "session",
            "admission",
            "membership",
            "active room presence",
            "call authority",
            "retained content is not deleted",
        )
    ):
        raise ValueError(
            "guest logout must document atomic scoped-authority cleanup "
            "without content deletion"
        )
    if (
        paths["/api/v1/guest/sessions/current"]["delete"]
        .get("responses", {})
        .get("403", {})
        .get("$ref")
        != "#/components/responses/Error"
    ):
        raise ValueError(
            "guest logout must document stale scoped authority as forbidden"
        )

    create_link = schemas.get("CreateGuestLinkRequest", {})
    create_properties = create_link.get("properties", {})
    if (
        create_link.get("additionalProperties") is not False
        or create_properties.get("expires_in_seconds", {}).get("minimum") != 600
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
            "CreateGuestLinkRequest must bound lifetime to 600..86400 seconds "
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
    expected_conversion_variants = [
        {"$ref": "#/components/schemas/ConvertVerifiedGuestAccountRequest"},
        {"$ref": "#/components/schemas/ConvertInstantRoomGuestAccountRequest"},
    ]
    if conversion_request.get("oneOf") != expected_conversion_variants:
        raise ValueError(
            "ConvertGuestAccountRequest must select the verified standard-link "
            "or conversation-only instant-room request"
        )

    verified_conversion = schemas.get("ConvertVerifiedGuestAccountRequest", {})
    verified_properties = verified_conversion.get("properties", {})
    conversion_verification_code = verified_properties.get("verification_code", {})
    conversion_password = verified_properties.get("password", {})
    if (
        verified_conversion.get("additionalProperties") is not False
        or set(verified_conversion.get("required", []))
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
            "ConvertVerifiedGuestAccountRequest must require an exact write-only "
            "verification_code and write-only password"
        )

    instant_conversion = schemas.get("ConvertInstantRoomGuestAccountRequest", {})
    instant_properties = instant_conversion.get("properties", {})
    instant_password = instant_properties.get("password", {})
    instant_email_description = instant_properties.get("email", {}).get(
        "description", ""
    )
    if (
        instant_conversion.get("additionalProperties") is not False
        or set(instant_conversion.get("required", [])) != {"email", "password"}
        or "verification_code" in instant_properties
        or instant_password.get("writeOnly") is not True
        or "readOnly" in instant_password
        or "Unverified" not in instant_email_description
        or "conversation-only" not in instant_conversion.get("description", "")
    ):
        raise ValueError(
            "ConvertInstantRoomGuestAccountRequest must require email/password, "
            "omit verification claims, and remain conversation-only"
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
    token_user = token_response.get("properties", {}).get("user", {})
    if (
        "access_scope" not in set(token_user.get("required", []))
        or set(
            token_user.get("properties", {})
            .get("access_scope", {})
            .get("enum", [])
        )
        != {"workspace", "conversation_only"}
    ):
        raise ValueError(
            "TokenResponse.user must expose workspace or conversation_only "
            "access_scope"
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

    guest_user = schemas.get("GuestUser", {})
    if (
        "access_scope" not in set(guest_user.get("required", []))
        or guest_user.get("properties", {}).get("access_scope")
        != {"const": "conversation_only"}
    ):
        raise ValueError("GuestUser must expose conversation_only access_scope")

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
            "self_service_conversion",
        }
        or guest_capabilities.get("properties", {}).get("conversion_enabled")
        != {"type": "boolean"}
        or guest_capabilities.get("properties", {}).get("email_hint", {}).get("type")
        != ["string", "null"]
        or guest_capabilities.get("properties", {}).get("self_service_conversion")
        != {
            "type": "boolean",
            "description": (
                "Present and true only for an instant-room guest eligible for "
                "conversation-only conversion; it is not evidence of verified email."
            ),
        }
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


def validate_instant_room_realtime_contract(asyncapi: dict[str, Any]) -> None:
    channels = asyncapi.get("channels", {})
    conversation_messages = channels.get("conversation", {}).get("messages", {})
    component_messages = asyncapi.get("components", {}).get("messages", {})
    schemas = asyncapi.get("components", {}).get("schemas", {})

    expected_messages = {
        "presenceState": ("PresenceState", "presence_state", "PresenceStatePayload"),
        "presenceDiff": ("PresenceDiff", "presence_diff", "PresenceDiffPayload"),
    }
    receive_refs = {
        item.get("$ref")
        for item in asyncapi.get("operations", {})
        .get("receiveConversationEvent", {})
        .get("messages", [])
        if isinstance(item, dict)
    }
    for channel_key, (
        component_name,
        event_name,
        payload_name,
    ) in expected_messages.items():
        expected_channel_ref = f"#/components/messages/{component_name}"
        if conversation_messages.get(channel_key) != {"$ref": expected_channel_ref}:
            raise ValueError(
                f"AsyncAPI conversation channel is missing instant-room message "
                f"{channel_key}"
            )
        message = component_messages.get(component_name, {})
        if (
            message.get("name") != event_name
            or message.get("payload", {}).get("$ref")
            != f"#/components/schemas/{payload_name}"
        ):
            raise ValueError(
                f"AsyncAPI {component_name} must bind {event_name} to {payload_name}"
            )
        receive_ref = f"#/channels/conversation/messages/{channel_key}"
        if receive_ref not in receive_refs:
            raise ValueError(
                f"receiveConversationEvent must include {receive_ref}"
            )

    lifecycle_channel_keys = {
        "ephemeralRoomCreated",
        "ephemeralRoomReactivated",
        "ephemeralRoomIdle",
        "ephemeralRoomExpired",
        "ephemeralRoomOwnerUpgraded",
    }
    if lifecycle_channel_keys & set(conversation_messages):
        raise ValueError(
            "AsyncAPI must not advertise durable instant-room lifecycle evidence "
            "as a client conversation-channel event"
        )

    presence_meta = schemas.get("PresenceMeta", {})
    presence_properties = presence_meta.get("properties", {})
    if (
        presence_meta.get("additionalProperties") is not False
        or set(presence_meta.get("required", [])) != {"account_type", "online_at"}
        or set(presence_properties)
        != {"account_type", "online_at", "phx_ref", "phx_ref_prev"}
        or set(
            presence_properties.get("account_type", {}).get("enum", [])
        )
        != {"human", "guest"}
        or any(
            presence_properties.get(field, {}).get("type") != "string"
            or presence_properties.get(field, {}).get("minLength") != 1
            or presence_properties.get(field, {}).get("maxLength") != 255
            or "Opaque" not in presence_properties.get(field, {}).get(
                "description", ""
            )
            for field in ("phx_ref", "phx_ref_prev")
        )
    ):
        raise ValueError(
            "PresenceMeta must expose only account_type, online_at, and the "
            "optional opaque Phoenix phx_ref transport fields"
        )

    presence_entry = schemas.get("PresenceEntry", {})
    if (
        presence_entry.get("additionalProperties") is not False
        or set(presence_entry.get("required", [])) != {"metas"}
        or set(presence_entry.get("properties", {})) != {"metas"}
    ):
        raise ValueError("PresenceEntry must contain only sanitized metas")

    presence_state = schemas.get("PresenceStatePayload", {})
    if (
        presence_state.get("propertyNames")
        != {"type": "string", "format": "uuid"}
        or presence_state.get("additionalProperties", {}).get("$ref")
        != "#/components/schemas/PresenceEntry"
    ):
        raise ValueError(
            "PresenceStatePayload must be a user-UUID map of bounded PresenceEntry"
        )

    presence_diff = schemas.get("PresenceDiffPayload", {})
    if (
        presence_diff.get("additionalProperties") is not False
        or set(presence_diff.get("required", [])) != {"joins", "leaves"}
        or set(presence_diff.get("properties", {})) != {"joins", "leaves"}
    ):
        raise ValueError("PresenceDiffPayload must expose only joins and leaves")

    forbidden_app_metadata = {
        "tenant_id",
        "connection_id",
        "session_id",
        "device_id",
        "token",
        "email",
        "ip",
        "generation",
    }
    if forbidden_app_metadata & set(presence_properties):
        raise ValueError("PresenceMeta exposes forbidden application metadata")


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


def validate_whiteboard_image_reference(element: dict[str, Any]) -> None:
    """Image elements name an approved durable asset, never arbitrary image bytes or URLs."""

    expected = {
        "if": {"properties": {"type": {"const": "image"}}, "required": ["type"]},
        "then": {
            "required": ["fileId"],
            "properties": {
                "fileId": {"type": "string", "format": "uuid"},
                "dataURL": {"type": "null"},
                "src": {"type": "null"},
                "url": {"type": "null"},
            },
        },
    }
    if expected not in element.get("allOf", []):
        raise ValueError("Whiteboard images require a durable asset UUID and reject inline or remote image data")


def validate_whiteboard_contract(openapi: dict[str, Any]) -> None:
    """Keep durable whiteboard limits and scoped member/guest APIs explicit."""

    paths = openapi.get("paths", {})
    route = paths.get(WHITEBOARD_PATH, {})
    if set(route) != {"parameters", "get", "post"}:
        raise ValueError("OpenAPI whiteboard operation route must expose only GET and POST")

    post = route.get("post", {})
    header = next(
        (
            item
            for item in post.get("parameters", [])
            if item.get("name") == "Idempotency-Key" and item.get("in") == "header"
        ),
        None,
    )
    if not header or header.get("required") is not True or header.get("schema") != {
        "type": "string",
        "minLength": 8,
        "maxLength": 128,
    }:
        raise ValueError("OpenAPI whiteboard writes require the bounded Idempotency-Key")

    request_ref = (
        post.get("requestBody", {})
        .get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("$ref")
    )
    if request_ref != "#/components/schemas/WhiteboardOperationRequest":
        raise ValueError("OpenAPI whiteboard writes require WhiteboardOperationRequest")
    if set(post.get("responses", {})) != {"200", "201", "403", "409", "422"}:
        raise ValueError("OpenAPI whiteboard writes must preserve replay/conflict responses")

    guest_route = paths.get(GUEST_WHITEBOARD_PATH, {})
    if set(guest_route) != {"get", "post"}:
        raise ValueError(
            "OpenAPI guest whiteboard route must expose only server-scoped GET and POST"
        )

    for method in ("get", "post"):
        if guest_route.get(method, {}).get("security") != [{"guestBearerAuth": []}]:
            raise ValueError(
                "OpenAPI guest whiteboard operations must require guestBearerAuth"
            )

    guest_get = guest_route["get"]
    guest_get_ref = (
        guest_get.get("responses", {})
        .get("200", {})
        .get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("$ref")
    )
    if (
        set(guest_get.get("responses", {})) != {"200", "401", "403"}
        or guest_get_ref != "#/components/schemas/WhiteboardOperationPage"
    ):
        raise ValueError(
            "OpenAPI guest whiteboard reads must preserve scoped replay responses"
        )

    guest_post = guest_route["post"]
    guest_header = next(
        (
            item
            for item in guest_post.get("parameters", [])
            if item.get("name") == "Idempotency-Key" and item.get("in") == "header"
        ),
        None,
    )
    if not guest_header or guest_header.get("required") is not True or guest_header.get(
        "schema"
    ) != {
        "type": "string",
        "minLength": 8,
        "maxLength": 128,
    }:
        raise ValueError(
            "OpenAPI guest whiteboard writes require the bounded Idempotency-Key"
        )

    guest_request_ref = (
        guest_post.get("requestBody", {})
        .get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("$ref")
    )
    if guest_request_ref != "#/components/schemas/WhiteboardOperationRequest":
        raise ValueError(
            "OpenAPI guest whiteboard writes require WhiteboardOperationRequest"
        )

    schemas = openapi.get("components", {}).get("schemas", {})
    element = schemas.get("WhiteboardElement", {})
    element_properties = element.get("properties", {})
    if (
        set(element.get("required", [])) != {"id", "type", "version", "versionNonce"}
        or set(element_properties.get("type", {}).get("enum", []))
        != WHITEBOARD_ELEMENT_TYPES
        or element_properties.get("link") != {"type": "null"}
        or element_properties.get("customData") != {"type": "null"}
    ):
        raise ValueError("OpenAPI whiteboard elements must preserve the safe SDK subset")

    validate_whiteboard_image_reference(element)

    elements = (
        schemas.get("WhiteboardScenePayload", {})
        .get("properties", {})
        .get("elements", {})
    )
    if elements.get("minItems") != 1 or elements.get("maxItems") != 200:
        raise ValueError("OpenAPI whiteboard scene batches must remain bounded to 200")

    capabilities = (
        schemas.get("StatusResponse", {})
        .get("properties", {})
        .get("capabilities", {})
    )
    if "whiteboards" not in capabilities.get("required", []) or capabilities.get(
        "properties", {}
    ).get("whiteboards", {}).get("type") != "boolean":
        raise ValueError("OpenAPI status must advertise the whiteboards capability")


def validate_whiteboard_realtime_contract(asyncapi: dict[str, Any]) -> None:
    """Require the dedicated authorized topic and its durable/ephemeral split."""

    channel = asyncapi.get("channels", {}).get("whiteboard", {})
    if channel.get("address") != "whiteboard:{conversationId}":
        raise ValueError("AsyncAPI whiteboard channel must use the dedicated topic")

    expected_messages = {
        "operationApplied": "#/components/messages/WhiteboardOperationApplied",
        "presenceCommand": "#/components/messages/WhiteboardPresenceCommand",
        "presence": "#/components/messages/WhiteboardPresence",
    }
    observed_messages = {
        key: value.get("$ref")
        for key, value in channel.get("messages", {}).items()
        if isinstance(value, dict)
    }
    if observed_messages != expected_messages:
        raise ValueError("AsyncAPI whiteboard channel must preserve operation and presence messages")

    operations = asyncapi.get("operations", {})
    expected_refs = {
        "sendWhiteboardPresence": {
            "#/channels/whiteboard/messages/presenceCommand"
        },
        "receiveWhiteboardEvent": {
            "#/channels/whiteboard/messages/operationApplied",
            "#/channels/whiteboard/messages/presence",
        },
    }
    for operation_name, expected in expected_refs.items():
        observed = {
            message.get("$ref")
            for message in operations.get(operation_name, {}).get("messages", [])
            if isinstance(message, dict)
        }
        if observed != expected:
            raise ValueError(f"AsyncAPI {operation_name} has an incomplete whiteboard message set")

    schemas = asyncapi.get("components", {}).get("schemas", {})
    image_element = schemas.get("WhiteboardElementPayload", {})
    if set(image_element.get("properties", {}).get("type", {}).get("enum", [])) != WHITEBOARD_ELEMENT_TYPES:
        raise ValueError("AsyncAPI whiteboard elements must preserve the safe SDK subset")
    validate_whiteboard_image_reference(image_element)
    pointer = schemas.get("WhiteboardPointer", {})
    if set(pointer.get("required", [])) != {"x", "y", "tool"} or pointer.get(
        "properties", {}
    ).get("tool", {}).get("enum") != ["pointer", "laser"]:
        raise ValueError("AsyncAPI whiteboard pointer must remain bounded and typed")

    presence = schemas.get("WhiteboardPresencePayload", {})
    if (
        presence.get("additionalProperties") is not False
        or set(presence.get("required", []))
        != {"user_id", "device_id", "pointer", "button", "selected_element_ids"}
        or presence.get("properties", {}).get("user_id")
        != {"type": "string", "format": "uuid"}
        or presence.get("properties", {}).get("device_id")
        != {"type": "string", "format": "uuid"}
    ):
        raise ValueError(
            "AsyncAPI whiteboard presence must identify the authorized user and device"
        )

    operation = schemas.get("WhiteboardOperationPayload", {})
    if operation.get("additionalProperties") is not False or set(
        operation.get("required", [])
    ) != {
        "id",
        "whiteboard_id",
        "tenant_id",
        "conversation_id",
        "actor_user_id",
        "client_operation_id",
        "sequence",
        "kind",
        "payload",
        "inserted_at",
    }:
        raise ValueError("AsyncAPI whiteboard operation must match the emitted projection")


def validate_enterprise_identity_contract(openapi: dict[str, Any]) -> None:
    """Freeze new credential boundaries and the factor challenge/session distinction."""

    paths = openapi.get("paths", {})
    schemas = openapi.get("components", {}).get("schemas", {})
    login = paths.get("/api/v1/sessions", {}).get("post", {}).get("responses", {}).get("200", {}).get("content", {}).get("application/json", {}).get("schema", {})
    expected = {"#/components/schemas/TokenResponse", "#/components/schemas/MfaChallenge"}
    if {item.get("$ref") for item in login.get("oneOf", [])} != expected:
        raise ValueError("Password sign in must distinguish a session from an MFA challenge")
    challenge = schemas.get("MfaChallenge", {})
    if challenge.get("additionalProperties") is not False or set(challenge.get("required", [])) != {"mfa_required", "challenge_token", "expires_in"} or set(challenge.get("properties", {})) != {"mfa_required", "challenge_token", "expires_in"} or challenge.get("properties", {}).get("expires_in") != {"const": 300}:
        raise ValueError("MFA challenges must be bounded, one-use, and contain no session credentials")
    token = challenge["properties"].get("challenge_token", {})
    if token.get("minLength") != 32 or token.get("maxLength") != 256 or challenge["properties"].get("mfa_required") != {"const": True}:
        raise ValueError("MFA challenges require a bounded unpredictable protocol credential")
    public_paths = ["/api/v1/auth/mfa", "/api/v1/auth/oidc/start", "/api/v1/auth/oidc/callback"]
    for path in public_paths:
        if paths.get(path, {}).get("post", {}).get("security") != []:
            raise ValueError(f"Enterprise authentication operation must explicitly use protocol credentials: {path}")
    protected_paths = ["/api/v1/me/security", "/api/v1/me/mfa/enroll", "/api/v1/me/mfa/confirm", "/api/v1/me/mfa/disable", "/api/v1/me/mfa/recovery-codes", "/api/v1/me/oidc/link/start", "/api/v1/me/oidc/link/callback", "/api/v1/me/oidc/step-up/start", "/api/v1/me/availability"]
    for path in protected_paths:
        if not paths.get(path):
            raise ValueError(f"Identity security operation is missing: {path}")
        for method, operation in paths.get(path, {}).items():
            if method in {"get", "post", "put"} and operation.get("security") != [{"bearerAuth": []}]:
                raise ValueError(f"Identity security requires the current human session: {path}")
    for path, item in paths.items():
        if not path.startswith("/scim/v2/"):
            continue
        for method, operation in item.items():
            if method not in {"get", "post", "put", "patch", "delete"}:
                continue
            if operation.get("security") != [{"serviceAccountAuth": []}] or operation.get("x-required-scope") != ("scim:read" if method == "get" else "scim:write"):
                raise ValueError("SCIM requires dedicated tenant-scoped service credentials")
            for response in operation.get("responses", {}).values():
                if "content" in response and set(response["content"]) != {"application/scim+json"}:
                    raise ValueError("SCIM resource and error responses require application/scim+json")
            if method in {"put", "patch", "delete"} and not any(parameter.get("name") == "If-Match" and parameter.get("required") is True for parameter in operation.get("parameters", [])):
                raise ValueError("SCIM lifecycle mutations require the observed resource version")
    denied = {"roles", "role", "entitlements", "platform_role", "password", "groups", "account_type"}
    for name in ["ScimUserCreate", "ScimUserUpdate", "ScimGroupCreate", "ScimGroupUpdate"]:
        schema = schemas.get(name, {})
        if schema.get("additionalProperties") is not False or denied & set(schema.get("properties", {})):
            raise ValueError("SCIM resource requests cannot grant application authority")
    codes = schemas.get("RecoveryCodes", {}).get("properties", {}).get("recovery_codes", {})
    if codes.get("minItems") != 10 or codes.get("maxItems") != 10:
        raise ValueError("MFA recovery code receipt must contain exactly ten one-use codes")


def validate_member_workflow_contract(
    openapi: dict[str, Any], payloads: dict[str, dict[str, Any]] | None = None
) -> None:
    """Retain private CAS, advisory roles and content-free retained evidence."""
    paths = openapi.get("paths", {})
    schemas = openapi.get("components", {}).get("schemas", {})
    operations = {
        ("/api/v1/me/workspace", "get"): ("MemberWorkspaceResponse", None),
        ("/api/v1/me/workspace", "put"): ("MemberWorkspaceResponse", "ReplaceMemberWorkspaceRequest"),
        ("/api/v1/me/onboarding", "patch"): ("MemberWorkspaceResponse", "UpdateMemberOnboardingRequest"),
        ("/api/v1/admin/role-permissions", "get"): ("FixedRolePermissionResponse", None),
        ("/api/v1/admin/users/{userId}/role-preview", "post"): ("UserRoleChangePreviewResponse", "PreviewUserRoleRequest"),
        ("/api/v1/admin/usage", "get"): ("UsageReportResponse", None),
        ("/api/v1/admin/usage/export", "get"): (None, None),
        ("/api/v1/admin/deletion-requests/{requestId}/timeline", "get"): ("DeletionRequestTimelineResponse", None),
        ("/api/v1/admin/deletion-requests/{requestId}/timeline/export", "get"): (None, None),
    }
    for (path, method), (response, request) in operations.items():
        operation = paths.get(path, {}).get(method, {})
        if operation.get("security") != [{"bearerAuth": []}]:
            raise ValueError(f"Member workflow requires current human bearerAuth: {method.upper()} {path}")
        content = operation.get("responses", {}).get("200", {}).get("content", {})
        if response and content.get("application/json", {}).get("schema") != {"$ref": f"#/components/schemas/{response}"}:
            raise ValueError(f"Member workflow has the wrong response projection: {path}")
        if request:
            body = operation.get("requestBody", {})
            if body.get("required") is not True or body.get("content", {}).get("application/json", {}).get("schema") != {"$ref": f"#/components/schemas/{request}"}:
                raise ValueError(f"Member workflow requires its versioned request body: {path}")
            if not {"409", "422", "428"} <= set(operation.get("responses", {})):
                raise ValueError(f"Member workflow requires CAS, invalid-input and proof/version errors: {path}")
        elif response is None and set(content) != {"text/csv"}:
            raise ValueError(f"Member workflow export requires text/csv: {path}")

    def exact_object(name: str, fields: set[str], required: set[str] | None = None) -> dict[str, Any]:
        value = schemas.get(name, {})
        if value.get("type") != "object" or value.get("additionalProperties") is not False or set(value.get("properties", {})) != fields or set(value.get("required", [])) != (fields if required is None else required):
            raise ValueError(f"{name} must retain its exact private/allowlisted projection")
        return value["properties"]

    exact_object("PrivateContact", {"id", "display_name"})
    group = exact_object("PrivateContactGroup", {"id", "name", "member_ids"})
    if group["name"].get("maxLength") != 80 or group["member_ids"].get("maxItems") != 50 or group["member_ids"].get("uniqueItems") is not True:
        raise ValueError("Private groups must retain bounded names and unique members")
    workspace = exact_object("MemberWorkspace", {"version", "contacts", "groups", "onboarding", "limits", "observed_at"})
    replacement = exact_object("ReplaceMemberWorkspaceRequest", {"version", "contact_ids", "groups"})
    onboarding = exact_object("UpdateMemberOnboardingRequest", {"version", "action"})
    for value in (workspace, replacement, onboarding):
        if value["version"] != {"type": "integer", "minimum": 0}:
            raise ValueError("Private workspace CAS must require the observed integer version including zero")
    if workspace["contacts"].get("maxItems") != 500 or replacement["contact_ids"].get("maxItems") != 500 or replacement["contact_ids"].get("uniqueItems") is not True or workspace["groups"].get("maxItems") != 20 or replacement["groups"].get("maxItems") != 20:
        raise ValueError("Private workspace inventory must retain contacts/groups bounds")
    if set(onboarding["action"].get("enum", [])) != {"dismiss", "resume", "reset"}:
        raise ValueError("Onboarding cannot invent profile completion authority")
    limits = exact_object("MemberWorkspaceLimits", {"contacts", "groups", "members_per_group"})
    if {name: value.get("const") for name, value in limits.items()} != {"contacts": 500, "groups": 20, "members_per_group": 50}:
        raise ValueError("Private workspace limits must match the retained owner bounds")

    if set(schemas.get("FixedTenantRole", {}).get("enum", [])) != {"member", "moderator", "admin", "compliance_admin", "security_admin", "owner"}:
        raise ValueError("Fixed roles cannot add custom or platform authority")
    capability = exact_object("RoleCapabilityFact", {"capability", "scope", "conditions"})
    if capability["scope"] != {"const": "tenant"} or set(capability["capability"].get("enum", [])) != {"administer_users", "manage_user_lifecycle", "manage_sessions", "manage_tenant_settings", "manage_invitations", "audit_tenant", "govern_tenant"} or set(capability["conditions"].get("items", {}).get("enum", [])) != {"active_tenant", "active_identity", "current_session", "recent_step_up", "workspace_access"}:
        raise ValueError("Role capability facts must retain tenant eligibility and current conditions")
    required_conditions = {"active_tenant", "active_identity", "current_session", "workspace_access"}
    if capability["conditions"].get("minItems") != 4 or {item.get("contains", {}).get("const") for item in capability["conditions"].get("allOf", [])} != required_conditions:
        raise ValueError("Role eligibility cannot omit current tenant, identity, session or workspace conditions")
    catalog = exact_object("FixedRolePermissionResponse", {"data"})["data"]
    role_set = set(schemas["FixedTenantRole"]["enum"])
    if catalog.get("minItems") != 6 or catalog.get("maxItems") != 6 or {item.get("contains", {}).get("properties", {}).get("role", {}).get("const") for item in catalog.get("allOf", [])} != role_set or any(item.get("minContains") != 1 or item.get("maxContains") != 1 for item in catalog.get("allOf", [])):
        raise ValueError("Fixed-role catalog must return each of the six existing roles exactly once")
    preview = exact_object("UserRoleChangePreview", {"target_id", "current_role", "requested_role", "current_version", "target_status", "target_access_scope", "role_policy_allows", "blockers", "added", "removed", "advisory", "scope", "governance_review_required"})
    if preview["advisory"] != {"const": True} or preview["scope"] != {"const": "tenant"} or preview["governance_review_required"] != {"const": True} or set(preview["blockers"].get("items", {}).get("enum", [])) != {"forbidden", "last_owner_required"}:
        raise ValueError("Role preview must remain advisory with eligible last-owner/policy blockers")
    exact_object("PreviewUserRoleRequest", {"role", "version"})

    report = exact_object("UsageReport", {"range", "observed_at", "coverage", "lifetime_complete", "sources"})
    if report["coverage"] != {"const": "currently_retained_records"} or report["lifetime_complete"] != {"const": False}:
        raise ValueError("Usage must state retained coverage and deny lifetime completeness")
    range_properties = exact_object("UsageReportRange", {"from", "through", "time_zone"})
    if range_properties["time_zone"] != {"const": "UTC"}:
        raise ValueError("Usage daily buckets must use UTC")
    metrics = {
        "identity": ({"active_humans", "active_services"}, {"humans_created", "services_created"}),
        "conversations": ({"active_conversations"}, {"direct_created", "group_created", "channel_created"}),
        "messages": ({"retained_messages"}, {"created", "current_active", "current_deleted", "current_moderated"}),
        "attachments": ({"ready_retained_count", "ready_retained_bytes"}, {"created", "ready_count", "ready_bytes"}),
        "calls": ({"current_active", "current_ending"}, {"started", "audio_started", "video_started", "status_active", "status_ending", "status_ended", "observed_room_seconds"}),
        "telephony": ({"current_ringing", "current_answered"}, {"started", "inbound_started", "outbound_started", "status_ringing", "status_answered", "status_declined", "status_no_answer", "status_cancelled", "status_failed", "status_ended", "status_busy", "observed_answered_seconds"}),
    }
    sources = exact_object("UsageReportSources", set(metrics))
    for source, (current, daily) in metrics.items():
        name = f"Usage{source.title()}"
        if sources[source] != {"$ref": f"#/components/schemas/{name}Source"}:
            raise ValueError("Usage requires exactly six canonical owner sources")
        variants = schemas.get(name + "Source", {}).get("oneOf", [])
        expected = [
            {"type": "object", "additionalProperties": False, "required": ["status", "data"], "properties": {"status": {"const": "available"}, "data": {"$ref": f"#/components/schemas/{name}Projection"}}},
            {"type": "object", "additionalProperties": False, "required": ["status", "data"], "properties": {"status": {"const": "unavailable"}, "data": {"type": "null"}}},
        ]
        if variants != expected:
            raise ValueError("Unavailable usage sources must contain null data, never invented zero totals")
        projection = exact_object(name + "Projection", {"observed_at", "earliest_retained_at", "current", "daily"})
        if projection["daily"].get("maxItems") != 31:
            raise ValueError("Usage daily projection must retain its 31-day bound")
        for suffix, fields in (("Current", current), ("DailyMetrics", daily)):
            values = exact_object(name + suffix, fields)
            if any(value != {"type": "integer", "minimum": 0} for value in values.values()):
                raise ValueError("Usage must expose only nonnegative content-free owner metrics")

    proof_keys = {"derived_erasure_version", "media_erasure_version", "meeting_erasure_version", "writer_fence_erasure_version"}
    count_keys = {"messages_tombstoned", "attachments_deleted", "deleted_object_count"}
    for name, fields in (("DeletionHistoryProofVersions", proof_keys), ("DeletionHistoryCounts", count_keys), ("DeletionHistoryEvidence", proof_keys | count_keys)):
        values = exact_object(name, fields, set())
        if any(value != {"type": "integer", "minimum": 0, "maximum": 9_007_199_254_740_991} for value in values.values()):
            raise ValueError("History proof/count facts must be bounded allowlisted integers")
    event = exact_object("DeletionHistoryEvent", {"id", "actor", "inserted_at", "action", "status", "attempt", "error_code", "version", "proof_versions", "counts"})
    if set(event["error_code"].get("enum", [])) != {"provider_failure", "verification_pending", "unavailable", None}:
        raise ValueError("History cannot disclose raw provider or worker errors")
    timeline = exact_object("DeletionRequestTimeline", {"request", "events", "limit", "next_cursor", "snapshot", "observed_at", "snapshot_observed_at", "coverage"})
    coverage = exact_object("DeletionHistoryCoverage", {"state", "retained_only", "version_lineage", "origin_present", "earliest_at", "snapshot_truncated", "captured_count", "retained_count", "maximum_events"})
    if coverage["retained_only"] != {"const": True} or coverage["version_lineage"] != {"const": "unproven"} or coverage["maximum_events"] != {"const": 5000} or timeline["events"].get("maxItems") != 50 or timeline["snapshot"].get("maxLength") != 12000:
        raise ValueError("History must retain bounded signed positions and explicit unproven retained coverage")

    exports = {
        "/api/v1/admin/usage/export": ({"Cache-Control", "Content-Disposition", "x-usage-from", "x-usage-through", "x-usage-time-zone", "x-usage-observed-at", "x-usage-unavailable-sources"}, "source,status,date,metric,value,observed_at,earliest_retained_at,coverage,range_from,range_through,time_zone"),
        "/api/v1/admin/deletion-requests/{requestId}/timeline/export": ({"Cache-Control", "Pragma", "Content-Disposition", "x-export-row-count", "x-export-truncated", "x-export-maximum-rows", "x-history-snapshot", "x-history-coverage", "x-history-retained-only", "x-history-observed-at"}, "inserted_at,actor_user_id,actor_kind,actor,action,status,attempt,error_code,version,proof_versions,counts"),
    }
    for path, (required_headers, columns) in exports.items():
        response = paths[path]["get"]["responses"]["200"]
        headers = response.get("headers", {})
        if set(headers) != required_headers or any(value.get("required") is not True for value in headers.values()):
            raise ValueError("CSV exports must retain every private range/snapshot/coverage/truncation receipt header")
        if response.get("x-csv-columns") != columns.split(","):
            raise ValueError("CSV exports must retain the exact allowlisted column order")

    if payloads is not None:
        families = {
            "member-workspace.v1.json": {"MemberWorkspaceResponse", "ReplaceMemberWorkspaceRequest", "UpdateMemberOnboardingRequest"},
            "role-permissions.v1.json": {"FixedRolePermissionResponse", "PreviewUserRoleRequest", "UserRoleChangePreviewResponse"},
            "usage-report.v1.json": {"UsageReportResponse"},
            "deletion-request-history.v1.json": {"DeletionRequestTimelineResponse"},
        }
        def portable(value: Any) -> Any:
            if isinstance(value, dict):
                return {key: item.replace("#/components/schemas/", "#/$defs/") if key == "$ref" else portable(item) for key, item in value.items()}
            if isinstance(value, list):
                return [portable(item) for item in value]
            return value
        for filename, roots in families.items():
            payload = payloads.get(filename, {})
            if {item.get("$ref") for item in payload.get("oneOf", [])} != {"#/$defs/" + name for name in roots} or not roots <= set(payload.get("$defs", {})):
                raise ValueError(f"Standalone member workflow payload roots are incomplete: {filename}")
            for name, definition in payload.get("$defs", {}).items():
                if name not in schemas or definition != portable(schemas[name]):
                    raise ValueError(f"Standalone member workflow schema diverges from canonical OpenAPI: {filename}:{name}")


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
    validate_telephony_contract(openapi)
    validate_phone_provisioning_contract(openapi, schemas["phone-provider-provisioning.v1.json"])
    validate_instant_room_contract(openapi)
    validate_guest_contract(openapi)
    validate_whiteboard_contract(openapi)
    validate_enterprise_identity_contract(openapi)
    validate_member_workflow_contract(openapi, schemas)

    asyncapi_path = CONTRACTS / "asyncapi" / "asyncapi.yaml"
    asyncapi = load_yaml(asyncapi_path)
    if asyncapi.get("asyncapi") != "3.0.0":
        raise ValueError("AsyncAPI contract must use version 3.0.0")
    for required in ("info", "channels", "operations", "components"):
        if required not in asyncapi:
            raise ValueError(f"AsyncAPI contract is missing {required}")
    validate_refs(asyncapi, asyncapi_path)
    validate_guest_realtime_contract(asyncapi)
    validate_instant_room_realtime_contract(asyncapi)
    validate_call_realtime_contract(asyncapi)
    validate_whiteboard_realtime_contract(asyncapi)

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
