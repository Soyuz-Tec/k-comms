#!/usr/bin/env python3
"""Reject a rendered production bundle that still contains fail-closed defaults."""

from __future__ import annotations

import base64
import binascii
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

import yaml


IMAGE_DIGEST = re.compile(r"^.+@sha256:[a-f0-9]{64}$")
PLACEHOLDER = re.compile(r"(?:\.invalid\b|CHANGE_ME|REPLACE_WITH)", re.IGNORECASE)


def validate(path: Path) -> list[str]:
    if not path.is_file():
        return [f"{path}: file does not exist"]

    try:
        documents = [document for document in yaml.safe_load_all(path.read_text(encoding="utf-8")) if document]
    except yaml.YAMLError:
        return [f"{path}: rendered bundle is not valid YAML"]

    return validate_documents(documents)


def validate_documents(documents: list[dict]) -> list[str]:
    errors: list[str] = []
    config = named_document(documents, "ConfigMap", "k-comms-config")

    if not config:
        return ["rendered bundle: missing ConfigMap k-comms-config"]

    data = config.get("data") or {}
    required_values = {
        "ALLOW_BOOTSTRAP": "false",
        "ALLOW_DEVELOPMENT_ADAPTERS": "false",
        "DATABASE_SSL": "true",
        "HSTS_ENABLED": "true",
        "NOTIFICATION_PROVIDER_MODE": "http",
        "ATTACHMENT_SCANNER_MODE": "http",
        "WEBHOOK_PROVIDER_MODE": "http",
    }
    for key, expected in required_values.items():
        if str(data.get(key, "")).lower() != expected:
            errors.append(f"ConfigMap k-comms-config: {key} must be {expected} for promotion")

    for key in (
        "PHX_HOST",
        "PUBLIC_APP_URL",
        "CORS_ORIGINS",
        "S3_PUBLIC_ENDPOINT",
        "S3_INTERNAL_ENDPOINT",
        "S3_BUCKET",
        "NOTIFICATION_PROVIDER_ENDPOINT",
        "NOTIFICATION_PROVIDER_NAME",
        "NOTIFICATION_PROVIDER_ALLOWED_HOSTS",
        "ATTACHMENT_SCANNER_ENDPOINT",
        "ATTACHMENT_SCANNER_PROVIDER_NAME",
        "ATTACHMENT_SCANNER_ALLOWED_HOSTS",
        "WEBHOOK_ALLOWED_HOSTS",
        "WEB_PUSH_VAPID_PUBLIC_KEY",
    ):
        value = str(data.get(key, ""))
        if not value or PLACEHOLDER.search(value):
            errors.append(f"ConfigMap k-comms-config: {key} is missing or still a placeholder")

    public_origin = validate_https_origin(data, "PUBLIC_APP_URL", errors)
    validate_https_origin(data, "S3_PUBLIC_ENDPOINT", errors)
    validate_https_origin(data, "S3_INTERNAL_ENDPOINT", errors)
    validate_provider(data, "NOTIFICATION_PROVIDER", errors)
    validate_provider(data, "ATTACHMENT_SCANNER", errors)
    validate_hosts(data.get("WEBHOOK_ALLOWED_HOSTS"), "WEBHOOK_ALLOWED_HOSTS", errors)
    validate_vapid(data.get("WEB_PUSH_VAPID_PUBLIC_KEY"), errors)

    if public_origin:
        if data.get("PHX_HOST") != public_origin.hostname:
            errors.append("ConfigMap k-comms-config: PHX_HOST must match PUBLIC_APP_URL")
        cors_origins = [item.strip() for item in str(data.get("CORS_ORIGINS", "")).split(",")]
        if public_origin.geturl().rstrip("/") not in cors_origins:
            errors.append("ConfigMap k-comms-config: CORS_ORIGINS must include PUBLIC_APP_URL")

    validate_images(documents, errors)
    validate_runtime_purposes(documents, errors)
    validate_database_egress(documents, errors)
    return errors


def validate_https_origin(data: dict, key: str, errors: list[str]):
    value = data.get(key)
    try:
        parsed = urlsplit(str(value or ""))
        hostname = parsed.hostname
    except ValueError:
        errors.append(f"ConfigMap k-comms-config: {key} must be an absolute HTTPS origin")
        return None
    if (
        parsed.scheme != "https"
        or not hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        errors.append(f"ConfigMap k-comms-config: {key} must be an absolute HTTPS origin")
        return None
    return parsed


def validate_provider(data: dict, prefix: str, errors: list[str]) -> None:
    endpoint_key = f"{prefix}_ENDPOINT"
    hosts_key = f"{prefix}_ALLOWED_HOSTS"
    hosts = validate_hosts(data.get(hosts_key), hosts_key, errors)

    try:
        endpoint = urlsplit(str(data.get(endpoint_key, "")))
        hostname = endpoint.hostname
        port = endpoint.port
    except ValueError:
        errors.append(f"ConfigMap k-comms-config: {endpoint_key} must be an HTTPS port-443 URL")
        return

    if (
        endpoint.scheme != "https"
        or not hostname
        or endpoint.username
        or endpoint.password
        or endpoint.fragment
        or port not in {None, 443}
    ):
        errors.append(f"ConfigMap k-comms-config: {endpoint_key} must be an HTTPS port-443 URL")
    elif hostname.lower() not in hosts:
        errors.append(f"ConfigMap k-comms-config: {endpoint_key} host must be present in {hosts_key}")


def validate_hosts(value, key: str, errors: list[str]) -> set[str]:
    hosts = {item.strip().lower().rstrip(".") for item in str(value or "").split(",") if item.strip()}
    if not hosts:
        errors.append(f"ConfigMap k-comms-config: {key} must contain explicit hostnames")
    return hosts


def validate_vapid(value, errors: list[str]) -> None:
    try:
        encoded = str(value or "")
        decoded = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    except (ValueError, binascii.Error):
        decoded = b""
    if len(decoded) != 65 or not decoded.startswith(b"\x04"):
        errors.append(
            "ConfigMap k-comms-config: WEB_PUSH_VAPID_PUBLIC_KEY must encode an uncompressed P-256 public key"
        )


def validate_images(documents: list[dict], errors: list[str]) -> None:
    expected = {
        ("Deployment", "k-comms-edge"),
        ("Deployment", "k-comms-worker"),
        ("Job", "k-comms-migrate"),
    }
    for kind, name in expected:
        document = named_document(documents, kind, name)
        if not document:
            errors.append(f"rendered bundle: missing {kind} {name}")
            continue
        containers = (
            document.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        )
        image = str(containers[0].get("image", "")) if containers else ""
        if not IMAGE_DIGEST.fullmatch(image):
            errors.append(f"{kind} {name}: image must use an immutable sha256 digest")


def validate_runtime_purposes(documents: list[dict], errors: list[str]) -> None:
    for kind, name in (
        ("Deployment", "k-comms-edge"),
        ("Deployment", "k-comms-worker"),
        ("Job", "k-comms-migrate"),
    ):
        document = named_document(documents, kind, name)
        if not document:
            continue
        containers = (
            document.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        )
        environment = {
            item.get("name"): item.get("value")
            for item in (containers[0].get("env", []) if containers else [])
        }
        purpose = environment.get("K_COMMS_RUNTIME_PURPOSE", "application")
        expected = "one_shot" if kind == "Job" else "application"
        if purpose != expected:
            errors.append(f"{kind} {name}: K_COMMS_RUNTIME_PURPOSE must be {expected}")


def validate_database_egress(documents: list[dict], errors: list[str]) -> None:
    policy = named_document(documents, "NetworkPolicy", "k-comms-managed-postgres-egress")
    if not policy:
        errors.append("rendered bundle: missing narrowed managed PostgreSQL egress policy")
        return

    cidrs = {
        peer.get("ipBlock", {}).get("cidr")
        for rule in policy.get("spec", {}).get("egress", [])
        for peer in rule.get("to", [])
        if peer.get("ipBlock")
    }
    if not cidrs or "0.0.0.0/0" in cidrs or "::/0" in cidrs:
        errors.append("NetworkPolicy k-comms-managed-postgres-egress: database CIDR must be narrowed")


def named_document(documents: list[dict], kind: str, name: str) -> dict | None:
    return next(
        (
            document
            for document in documents
            if document.get("kind") == kind
            and document.get("metadata", {}).get("name") == name
        ),
        None,
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate_production_bundle.py RENDERED_BUNDLE.yaml")

    errors = validate(Path(sys.argv[1]))
    if errors:
        raise SystemExit("Production promotion preflight failed:\n" + "\n".join(errors))

    print("Production promotion preflight passed")


if __name__ == "__main__":
    main()
