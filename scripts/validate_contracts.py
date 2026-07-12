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


def main() -> None:
    schema_paths = sorted((CONTRACTS / "json-schema").glob("*.json"))
    if not schema_paths:
        raise ValueError("no JSON Schema contracts found")

    for path in schema_paths:
        schema = json.loads(path.read_text(encoding="utf-8"))
        validator_for(schema).check_schema(schema)
        validate_refs(schema, path)

    openapi_path = CONTRACTS / "openapi" / "openapi.yaml"
    openapi = load_yaml(openapi_path)
    validate_openapi(openapi)
    validate_refs(openapi, openapi_path)

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
