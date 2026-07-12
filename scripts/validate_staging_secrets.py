#!/usr/bin/env python3
"""Validate deployment env files without ever echoing their values."""

from __future__ import annotations

import base64
import binascii
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")
KEY_ID = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
TENANT_SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
EMAIL = re.compile(r"^[^\s]+@[^\s]+\.[^\s]+$")

RUNTIME_REQUIRED = {
    "DATABASE_URL",
    "SECRET_KEY_BASE",
    "PASSWORD_RECOVERY_SIGNING_KEY",
    "RELEASE_COOKIE",
    "S3_ACCESS_KEY_ID",
    "S3_SECRET_ACCESS_KEY",
    "METRICS_BEARER_TOKEN",
}

STAGING_RUNTIME_REQUIRED = RUNTIME_REQUIRED | {
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
    "MINIO_ROOT_USER",
    "MINIO_ROOT_PASSWORD",
}

BOOTSTRAP_REQUIRED = {
    "BOOTSTRAP_TENANT_NAME",
    "BOOTSTRAP_TENANT_SLUG",
    "BOOTSTRAP_OWNER_DISPLAY_NAME",
    "BOOTSTRAP_OWNER_EMAIL",
    "BOOTSTRAP_OWNER_PASSWORD",
}

PROVIDER_REQUIRED = {
    "NOTIFICATION_PROVIDER_TOKEN",
    "ATTACHMENT_SCANNER_TOKEN",
}

ENCRYPTION_ALTERNATIVES = {
    "webhook secret encryption": (
        "WEBHOOK_SECRET_ENCRYPTION_KEY",
        "WEBHOOK_SECRET_ENCRYPTION_KEYS",
    ),
    "push subscription encryption": (
        "PUSH_SUBSCRIPTION_ENCRYPTION_KEY",
        "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS",
    ),
}

AES_256_KEYS = {
    "WEBHOOK_SECRET_ENCRYPTION_KEY",
    "PUSH_SUBSCRIPTION_ENCRYPTION_KEY",
}

KEYRING_KEYS = {
    "WEBHOOK_SECRET_ENCRYPTION_KEYS",
    "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS",
}

MINIMUM_BYTES = {
    "SECRET_KEY_BASE": 64,
    "PASSWORD_RECOVERY_SIGNING_KEY": 32,
    "RELEASE_COOKIE": 32,
    "METRICS_BEARER_TOKEN": 32,
    "POSTGRES_PASSWORD": 16,
    "MINIO_ROOT_PASSWORD": 16,
    "S3_SECRET_ACCESS_KEY": 16,
    "NOTIFICATION_PROVIDER_TOKEN": 16,
    "ATTACHMENT_SCANNER_TOKEN": 16,
}


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    values: dict[str, str] = {}
    lines: dict[str, int] = {}

    if not path.is_file():
        return [f"{path}: file does not exist"]

    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            errors.append(f"{path}:{number}: expected KEY=VALUE")
            continue

        key, value = line.split("=", 1)
        if not KEY.fullmatch(key):
            errors.append(f"{path}:{number}: invalid key name")
        if key in values:
            errors.append(f"{path}:{number}: duplicate key {key}")
        values[key] = value
        lines[key] = number

        if not value.strip():
            errors.append(f"{path}:{number}: {key} is empty")
        elif value != value.strip():
            errors.append(f"{path}:{number}: {key} has leading or trailing whitespace")
        elif contains_placeholder(value):
            errors.append(f"{path}:{number}: {key} still contains an example placeholder")

    if not values:
        errors.append(f"{path}: no secret values found")

    required = required_keys(path)
    for missing in sorted(required - values.keys()):
        errors.append(f"{path}: missing required key {missing}")

    if is_runtime_file(path):
        for description, alternatives in ENCRYPTION_ALTERNATIVES.items():
            if not any(configured(values.get(key)) for key in alternatives):
                errors.append(
                    f"{path}: {description} requires one of {alternatives[0]} or {alternatives[1]}"
                )

    for key, value in values.items():
        if not semantically_validatable(value):
            continue
        number = lines[key]

        if key in AES_256_KEYS and not valid_aes_256_key(value):
            errors.append(
                f"{path}:{number}: {key} must be exactly 32 bytes or standard Base64 encoding of 32 bytes"
            )
        if key in KEYRING_KEYS:
            errors.extend(validate_keyring(path, number, key, value))
        if key in MINIMUM_BYTES and len(value.encode("utf-8")) < MINIMUM_BYTES[key]:
            errors.append(
                f"{path}:{number}: {key} must contain at least {MINIMUM_BYTES[key]} bytes"
            )

    if is_runtime_file(path) and semantically_validatable(values.get("DATABASE_URL")):
        errors.extend(validate_database_url(path, lines["DATABASE_URL"], values["DATABASE_URL"]))

    if path.name.lower() in {"secrets.env", "secrets.env.example"}:
        errors.extend(validate_staging_relationships(path, values, lines))

    if "bootstrap" in path.name.lower():
        errors.extend(validate_bootstrap_identity(path, values, lines))

    return errors


def valid_aes_256_key(value: str) -> bool:
    if len(value.encode("utf-8")) == 32:
        return True

    try:
        return len(base64.b64decode(value, validate=True)) == 32
    except (binascii.Error, ValueError):
        return False


def validate_keyring(path: Path, number: int, key: str, value: str) -> list[str]:
    errors: list[str] = []
    seen_ids: set[str] = set()
    entries = value.split(",")

    if not entries:
        return [f"{path}:{number}: {key} must contain key_id:Base64Key entries"]

    for entry in entries:
        parts = entry.split(":", 1)
        if len(parts) != 2 or not KEY_ID.fullmatch(parts[0]):
            errors.append(f"{path}:{number}: {key} contains an invalid key identifier")
            continue
        key_id, encoded = parts
        if key_id in seen_ids:
            errors.append(f"{path}:{number}: {key} contains duplicate key identifiers")
        seen_ids.add(key_id)
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError):
            decoded = b""
        if len(decoded) != 32:
            errors.append(f"{path}:{number}: {key} entries must encode exactly 32 bytes")

    return errors


def validate_database_url(path: Path, number: int, value: str) -> list[str]:
    errors: list[str] = []

    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError:
        return [f"{path}:{number}: DATABASE_URL is malformed"]

    database = parsed.path.lstrip("/")

    if (
        parsed.scheme not in {"ecto", "postgres", "postgresql"}
        or not hostname
        or not parsed.username
        or parsed.password is None
        or not database
        or "/" in database
        or parsed.fragment
    ):
        errors.append(
            f"{path}:{number}: DATABASE_URL must include a supported scheme, credentials, host, and database"
        )

    if port is not None and not 1 <= port <= 65535:
        errors.append(f"{path}:{number}: DATABASE_URL contains an invalid port")

    return errors


def validate_staging_relationships(
    path: Path, values: dict[str, str], lines: dict[str, int]
) -> list[str]:
    errors: list[str] = []
    database_url = values.get("DATABASE_URL")

    if semantically_validatable(database_url):
        try:
            parsed = urlsplit(database_url)
            hostname = parsed.hostname
            port = parsed.port
        except ValueError:
            return errors
        expected_database = parsed.path.lstrip("/")
        comparisons = {
            "POSTGRES_USER": unquote(parsed.username or ""),
            "POSTGRES_PASSWORD": unquote(parsed.password or ""),
            "POSTGRES_DB": unquote(expected_database),
        }
        for key, actual in comparisons.items():
            if semantically_validatable(values.get(key)) and values[key] != actual:
                errors.append(f"{path}:{lines[key]}: {key} must match DATABASE_URL")
        if hostname and hostname != "postgres":
            errors.append(
                f"{path}:{lines['DATABASE_URL']}: DATABASE_URL host must be postgres for the portable staging overlay"
            )
        if port not in {None, 5432}:
            errors.append(
                f"{path}:{lines['DATABASE_URL']}: DATABASE_URL port must be 5432 for the portable staging overlay"
            )

    for application_key, minio_key in (
        ("S3_ACCESS_KEY_ID", "MINIO_ROOT_USER"),
        ("S3_SECRET_ACCESS_KEY", "MINIO_ROOT_PASSWORD"),
    ):
        if (
            semantically_validatable(values.get(application_key))
            and semantically_validatable(values.get(minio_key))
            and values[application_key] != values[minio_key]
        ):
            errors.append(
                f"{path}:{lines[application_key]}: {application_key} must match {minio_key} for the bundled MinIO service"
            )

    return errors


def validate_bootstrap_identity(
    path: Path, values: dict[str, str], lines: dict[str, int]
) -> list[str]:
    errors: list[str] = []
    checks = (
        ("BOOTSTRAP_TENANT_NAME", lambda value: 2 <= len(value) <= 120, "2 to 120 characters"),
        (
            "BOOTSTRAP_TENANT_SLUG",
            lambda value: 2 <= len(value) <= 80 and bool(TENANT_SLUG.fullmatch(value)),
            "a 2 to 80 character lowercase slug",
        ),
        (
            "BOOTSTRAP_OWNER_DISPLAY_NAME",
            lambda value: 1 <= len(value) <= 120,
            "1 to 120 characters",
        ),
        (
            "BOOTSTRAP_OWNER_EMAIL",
            lambda value: bool(EMAIL.fullmatch(value)),
            "a valid email address",
        ),
        (
            "BOOTSTRAP_OWNER_PASSWORD",
            lambda value: 12 <= len(value) <= 256,
            "12 to 256 characters",
        ),
    )

    for key, predicate, requirement in checks:
        value = values.get(key)
        if semantically_validatable(value) and not predicate(value):
            errors.append(f"{path}:{lines[key]}: {key} must be {requirement}")

    return errors


def required_keys(path: Path) -> set[str]:
    name = path.name.lower()
    if "bootstrap" in name:
        return BOOTSTRAP_REQUIRED
    if name in {"provider-secrets.env", "provider-secrets.env.example"}:
        return PROVIDER_REQUIRED
    if name in {"runtime-secrets.env", "runtime-secrets.env.example"}:
        return RUNTIME_REQUIRED
    if name in {"secrets.env", "secrets.env.example"}:
        return STAGING_RUNTIME_REQUIRED
    return set()


def is_runtime_file(path: Path) -> bool:
    return path.name.lower() in {
        "runtime-secrets.env",
        "runtime-secrets.env.example",
        "secrets.env",
        "secrets.env.example",
    }


def configured(value: str | None) -> bool:
    return bool(value and value.strip() and not contains_placeholder(value))


def semantically_validatable(value: str | None) -> bool:
    return configured(value) and value == value.strip()


def contains_placeholder(value: str) -> bool:
    upper = value.upper()
    return "CHANGE_ME" in upper or "REPLACE_WITH" in upper


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: validate_staging_secrets.py ENV_FILE [ENV_FILE ...]")

    errors = [error for argument in sys.argv[1:] for error in validate(Path(argument))]
    if errors:
        raise SystemExit("Deployment secret validation failed:\n" + "\n".join(errors))

    print(f"Deployment secret validation passed: {len(sys.argv) - 1} file(s)")


if __name__ == "__main__":
    main()
