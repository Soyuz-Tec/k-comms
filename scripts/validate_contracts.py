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

REQUIRED_MUTATION_BODIES = {
    ("/api/v1/me/profile", "patch"),
    ("/api/v1/me/password", "put"),
    ("/api/v1/conversations/{conversationId}", "patch"),
    ("/api/v1/conversations/{conversationId}/members/{userId}", "patch"),
    ("/api/v1/conversations/{conversationId}/members/{userId}", "delete"),
    ("/api/v1/conversations/{conversationId}/archive", "post"),
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

    asyncapi_path = CONTRACTS / "asyncapi" / "asyncapi.yaml"
    asyncapi = load_yaml(asyncapi_path)
    if asyncapi.get("asyncapi") != "3.0.0":
        raise ValueError("AsyncAPI contract must use version 3.0.0")
    for required in ("info", "channels", "operations", "components"):
        if required not in asyncapi:
            raise ValueError(f"AsyncAPI contract is missing {required}")
    validate_refs(asyncapi, asyncapi_path)

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
