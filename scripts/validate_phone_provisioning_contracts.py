#!/usr/bin/env python3
"""Validate only ADR-0107's exact HTTP and secret-free payload contracts."""
from __future__ import annotations

import json
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "/api/v1/admin/telephony/provisioning"
OPERATIONS = {
    (PREFIX, "get"): (None, "PhoneProvisioningStateResponse"),
    (PREFIX + "/inspect", "post"): (
        "InspectPhoneProvisioningRequest", "PhoneProvisioningReceiptResponse"),
    (PREFIX + "/{commandId}/apply", "post"): (
        "PhoneProvisioningActionRequest", "PhoneProvisioningReceiptResponse"),
    (PREFIX + "/{commandId}/reconcile", "post"): (
        "PhoneProvisioningActionRequest", "PhoneProvisioningReceiptResponse"),
}
ASSIGNMENT_FIELDS = {"user_id", "phone_number", "extension", "inbound_trunk_id", "outbound_trunk_id"}
RECEIPT_FIELDS = {"id", "request_id", "status", "version", "assignment_version", "desired",
                  "dispatch_ready", "dispatch_rule_id", "observed_at", "failure_reason", "effect_in_progress"}
EXPECTED_FIELDS = {
    "PhoneProvisioningAssignment": ASSIGNMENT_FIELDS,
    "InspectPhoneProvisioningRequest": ASSIGNMENT_FIELDS | {"reason", "assignment_version", "idempotency_key"},
    "PhoneProvisioningActionRequest": {"version", "reason"},
    "PhoneProvisioningProvider": {"enabled", "ready", "reason", "number_purchase", "trunk_credentials_edit"},
    "PhoneProvisioningReceipt": RECEIPT_FIELDS,
    "PhoneProvisioningState": {"provider", "assignment_version", "commands"},
    "PhoneProvisioningStateResponse": {"data"},
    "PhoneProvisioningReceiptResponse": {"data"},
}
STATUSES = {"inspecting", "verified", "applying", "unknown", "applied", "failed", "reconciling"}


def component_refs(value):
    if isinstance(value, dict):
        return {key: component_refs(item) for key, item in value.items()}
    if isinstance(value, list):
        return [component_refs(item) for item in value]
    if isinstance(value, str):
        return value.replace("#/$defs/", "#/components/schemas/")
    return value


def validate_phone_provisioning_contract(openapi: dict, schema: dict) -> None:
    Draft202012Validator.check_schema(schema)
    definitions = schema.get("$defs", {})
    if set(definitions) != set(EXPECTED_FIELDS):
        raise ValueError("Phone provisioning JSON Schema must contain only the owned DTOs")
    components = openapi.get("components", {}).get("schemas", {})
    for name, fields in EXPECTED_FIELDS.items():
        definition = definitions[name]
        if (definition.get("type") != "object" or definition.get("additionalProperties") is not False
                or set(definition.get("required", [])) != fields
                or set(definition.get("properties", {})) != fields):
            raise ValueError(f"{name} must require exactly its bounded secret-free owner fields")
        if components.get(name) != component_refs(definition):
            raise ValueError(f"OpenAPI and JSON Schema disagree for {name}")

    receipt = definitions["PhoneProvisioningReceipt"]["properties"]
    if (set(receipt["status"].get("enum", [])) != STATUSES
            or receipt["version"].get("minimum") != 1
            or receipt["assignment_version"].get("minimum") != 0):
        raise ValueError("Phone receipts must preserve all durable outcomes and both CAS generations")
    for name in ("InspectPhoneProvisioningRequest", "PhoneProvisioningActionRequest"):
        reason = definitions[name]["properties"]["reason"]
        if reason.get("minLength") != 3 or reason.get("maxLength") != 500:
            raise ValueError("Phone provisioning writes require a bounded audited reason")
    key = definitions["InspectPhoneProvisioningRequest"]["properties"]["idempotency_key"]
    if key.get("format") != "uuid":
        raise ValueError("Phone inspection idempotency must be an actual UUID")
    provider = definitions["PhoneProvisioningProvider"]["properties"]
    if any(provider[name].get("const") is not False for name in ("number_purchase", "trunk_credentials_edit")):
        raise ValueError("SIP management must not advertise carrier purchase or credential editing")
    if definitions["PhoneProvisioningState"]["properties"]["commands"].get("maxItems") != 10:
        raise ValueError("Phone command listing must remain bounded to ten current receipts")

    paths = openapi.get("paths", {})
    owned = {path for path in paths if "telephony/provisioning" in path}
    if owned != {path for path, _method in OPERATIONS}:
        raise ValueError("Phone provisioning must expose only the four actual /api/v1 owner routes")
    for (path, method), (request, response) in OPERATIONS.items():
        route = paths.get(path, {})
        if set(route) != {method}:
            raise ValueError(f"Phone provisioning {path} has an undeclared method")
        operation = route[method]
        if operation.get("security") != [{"bearerAuth": []}]:
            raise ValueError(f"Phone provisioning {path} requires current human bearer authentication")
        responses = operation.get("responses", {})
        required_statuses = {"200", "401", "403", "404", "409", "422", "426", "428", "503"} if request else {"200", "401", "403"}
        if set(responses) != required_statuses:
            raise ValueError(f"Phone provisioning {path} must retain authorization/CAS/step-up statuses")
        success = responses["200"]
        if success.get("content", {}).get("application/json", {}).get("schema") != {"$ref": f"#/components/schemas/{response}"}:
            raise ValueError(f"Phone provisioning {path} has the wrong response DTO")
        if success.get("headers", {}).get("Cache-Control", {}).get("schema") != {"const": "no-store"}:
            raise ValueError("Phone owner responses must not be cached")
        if request:
            body = operation.get("requestBody", {})
            if (body.get("required") is not True or body.get("content", {}).get("application/json", {}).get("schema")
                    != {"$ref": f"#/components/schemas/{request}"}):
                raise ValueError(f"Phone provisioning {path} requires its exact mutation body")
        if "{commandId}" in path:
            if operation.get("parameters") != [{"name": "commandId", "in": "path", "required": True,
                                                  "schema": {"type": "string", "format": "uuid"}}]:
                raise ValueError("Phone apply/reconcile must address the exact command UUID")


def main() -> None:
    canonical = ROOT / "contracts/openapi/openapi.yaml"
    mirror = ROOT / "docs/04-interfaces/openapi/openapi.yaml"
    if canonical.read_bytes() != mirror.read_bytes():
        raise ValueError("Phone OpenAPI documentation mirror is stale")
    schema = json.loads((ROOT / "contracts/json-schema/phone-provider-provisioning.v1.json").read_text())
    validate_phone_provisioning_contract(yaml.safe_load(canonical.read_text()), schema)
    print("Phone provisioning: four exact routes, eight strict DTOs, JSON Schema/OpenAPI and mirror PASS")


if __name__ == "__main__":
    main()
