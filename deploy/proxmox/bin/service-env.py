#!/usr/bin/env python3
"""Generate and verify least-privilege Proxmox container environments (ADR-0082)."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import uuid

# Explicitly reviewed inputs; new runtime controls require an ownership decision.
APP_KEYS = set("""
ACCESS_TOKEN_TTL_SECONDS
ALLOW_BOOTSTRAP
ALLOW_DEVELOPMENT_ADAPTERS
ATTACHMENT_SCANNER_ALLOWED_HOSTS
ATTACHMENT_SCANNER_ENDPOINT
ATTACHMENT_SCANNER_MODE
ATTACHMENT_SCANNER_PROVIDER_NAME
ATTACHMENT_SCANNER_TIMEOUT_MS
ATTACHMENT_SCANNER_TOKEN
AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS
AUDIO_PROVIDER_MODE
AUDIO_TOKEN_TTL_SECONDS
CLUSTER_DNS_QUERY
CORS_ORIGINS
CSP_CONNECT_SOURCES
DATABASE_SSL
DATABASE_SSL_CA_FILE
DATABASE_SSL_SERVER_NAME
DATABASE_URL
DIRECT_AUDIO_P2P_ENABLED
DIRECT_AUDIO_STUN_URLS
HSTS_ENABLED
IMMERSIVE_MODE_ENABLED
INSTANT_ROOMS_ENABLED
INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS
INSTANT_ROOM_MAX_PARTICIPANTS
INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS
INSTANT_ROOM_PRESENCE_LEASE_SECONDS
INSTANT_ROOM_RECONNECT_GRACE_SECONDS
INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS
INSTANT_ROOM_TENANT_SLUG
K_COMMS_ALLOW_BOOTSTRAP_PLATFORM_ROLE
K_COMMS_BOOTSTRAP_PLATFORM_ROLE
K_COMMS_BOOTSTRAP_PLATFORM_ROLE_TTL_SECONDS
K_COMMS_INSTANCE_ID
K_COMMS_LIVEKIT_TOPOLOGY
K_COMMS_LOCAL_RELEASE
K_COMMS_LOCAL_RELEASE_HOST
K_COMMS_MANAGED_LIVEKIT_CONFIRMATION
K_COMMS_MIGRATION_LOCK_TIMEOUT_MS
K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS
K_COMMS_PLATFORM_ROLE_MANAGEMENT_SECRET
K_COMMS_QUALIFICATION_APP_CONFIRMATION
K_COMMS_QUALIFICATION_APP_ORIGIN
K_COMMS_QUALIFICATION_SHARE_ORIGIN
K_COMMS_RELEASE_EXPOSURE_MODE
K_COMMS_ROLE
K_COMMS_RUNTIME_PURPOSE
K_COMMS_TRUSTED_EDGE_CONFIRMATION
LIVEKIT_API_KEY
LIVEKIT_API_SECRET
LIVEKIT_API_URL
LIVEKIT_SERVER_URL
METRICS_BEARER_TOKEN
NOTIFICATION_PROVIDER_ALLOWED_HOSTS
NOTIFICATION_PROVIDER_ENDPOINT
NOTIFICATION_PROVIDER_MODE
NOTIFICATION_PROVIDER_NAME
NOTIFICATION_PROVIDER_TIMEOUT_MS
NOTIFICATION_PROVIDER_TOKEN
PASSWORD_RECOVERY_JITTER_MS
PASSWORD_RECOVERY_MIN_RESPONSE_MS
PASSWORD_RECOVERY_RETENTION_SECONDS
PASSWORD_RECOVERY_SIGNING_KEY
PASSWORD_RECOVERY_TTL_SECONDS
PHX_HOST
POOL_SIZE
PORT
PUBLIC_APP_URL
PUSH_SUBSCRIPTION_ENCRYPTION_KEY
PUSH_SUBSCRIPTION_ENCRYPTION_KEYS
PUSH_SUBSCRIPTION_ENCRYPTION_KEY_ID
S3_ACCESS_KEY_ID
S3_BUCKET
S3_DOWNLOAD_URL_TTL_SECONDS
S3_INTERNAL_ENDPOINT
S3_PUBLIC_ENDPOINT
S3_REGION
S3_SECRET_ACCESS_KEY
S3_URL_TTL_SECONDS
SECRET_KEY_BASE
SESSION_ABSOLUTE_TTL_SECONDS
SESSION_TTL_SECONDS
STUN_URLS
TRUSTED_PROXY_CIDRS
TURN_CREDENTIAL_TTL_SECONDS
TURN_STATIC_AUTH_SECRET
TURN_URLS
WEBHOOK_ALLOWED_HOSTS
WEBHOOK_PROVIDER_MODE
WEBHOOK_SECRET_ENCRYPTION_KEY
WEBHOOK_SECRET_ENCRYPTION_KEYS
WEBHOOK_SECRET_ENCRYPTION_KEY_ID
WEBHOOK_TIMEOUT_MS
WEB_PUSH_VAPID_PUBLIC_KEY
""".split())

POSTGRES_KEYS = {"POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"}
MINIO_KEYS = {"MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD", "MINIO_API_CORS_ALLOW_ORIGIN"}
LIVEKIT_KEYS = {"LIVEKIT_KEYS"}
BOOTSTRAP_KEYS = {"BOOTSTRAP_TENANT_NAME", "BOOTSTRAP_TENANT_SLUG", "BOOTSTRAP_OWNER_DISPLAY_NAME",
                  "BOOTSTRAP_OWNER_EMAIL", "BOOTSTRAP_OWNER_PASSWORD"}
# Host configuration only; never copied into any container.
HOST_KEYS = {"K_COMMS_RELEASE_HOST", "METRICS_ALLOW_UNAUTHENTICATED"}
SERVICES = {
    "app": APP_KEYS, "postgres": POSTGRES_KEYS, "minio": MINIO_KEYS,
    "livekit": LIVEKIT_KEYS, "object-admin": {"MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD", "S3_BUCKET"},
    "bootstrap": BOOTSTRAP_KEYS,
}
KNOWN_KEYS = APP_KEYS | POSTGRES_KEYS | MINIO_KEYS | LIVEKIT_KEYS | BOOTSTRAP_KEYS | HOST_KEYS
REQUIRED_KEYS = POSTGRES_KEYS | {"MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD", "LIVEKIT_KEYS",
    "DATABASE_URL", "SECRET_KEY_BASE", "PASSWORD_RECOVERY_SIGNING_KEY", "S3_ACCESS_KEY_ID",
    "S3_SECRET_ACCESS_KEY", "S3_BUCKET", "PUBLIC_APP_URL"}


class EnvironmentError(Exception):
    """Messages contain names and controls only, never secret values."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EnvironmentError(message)


def secure(path: Path, mode: int, owner: int, directory: bool = False) -> None:
    info = path.lstat()
    require((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            and info.st_uid == owner and stat.S_IMODE(info.st_mode) == mode,
            "Environment source or generation has unsafe type, owner, or mode")


def parse_source(source: Path, owner: int = 0) -> dict[str, str]:
    secure(source, 0o600, owner)
    require(source.stat().st_size <= 256 * 1024, "Environment source exceeds its size limit")
    values = {}
    for line in source.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, delimiter, value = line.partition("=")
        require(delimiter == "=" and re.fullmatch(r"[A-Z][A-Z0-9_]*", name) is not None,
                "Environment source contains an invalid assignment")
        require(name in KNOWN_KEYS, f"Environment input has no approved owner: {name}")
        require(name not in values, f"Environment source repeats an input: {name}")
        require(not any(ord(char) < 32 or ord(char) == 127 for char in value),
                f"Environment input contains a control character: {name}")
        require("CHANGE_ME" not in value, f"Environment input still contains a placeholder: {name}")
        values[name] = value
    for name in sorted(REQUIRED_KEYS):
        require(bool(values.get(name)), f"Required environment input is missing or empty: {name}")
    return values


def contents(values: dict[str, str], service: str) -> str:
    return "".join(f"{key}={values[key]}\n" for key in sorted(SERVICES[service]) if key in values)


def active_generation(destination: Path, owner: int = 0) -> Path:
    secure(destination, 0o700, owner, directory=True)
    current = destination / "current"
    require(current.is_symlink(), "Service environment pointer is missing or invalid")
    name = os.readlink(current)
    require(re.fullmatch(r"generation-[0-9a-f]{32}", name) is not None,
            "Service environment pointer escapes its generation directory")
    generation = destination / name
    secure(generation, 0o700, owner, directory=True)
    return generation


def check(values: dict[str, str], destination: Path, owner: int = 0) -> None:
    generation = active_generation(destination, owner)
    require({path.name for path in generation.iterdir()} == {f"{name}.env" for name in SERVICES},
            "Service environment generation has unexpected files")
    for service in SERVICES:
        path = generation / f"{service}.env"
        secure(path, 0o600, owner)
        require(path.read_text(encoding="utf-8") == contents(values, service),
                f"Service environment is stale or has unauthorized inputs: {service}")


def generate(source: Path, destination: Path, owner: int = 0) -> None:
    values = parse_source(source, owner)
    # The trusted source parent is not writable by any non-owner.
    parent = source.parent.lstat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == owner
            and not stat.S_IMODE(parent.st_mode) & 0o022,
            "Environment source directory has unsafe ownership or permissions")
    require(destination.parent.resolve() == source.parent.resolve(),
            "Service environments must share the protected source directory")
    if not destination.exists() and not destination.is_symlink():
        destination.mkdir(mode=0o700)
    secure(destination, 0o700, owner, directory=True)
    current = destination / "current"
    previous = active_generation(destination, owner) if current.is_symlink() else None
    require(previous is not None or not current.exists(), "Service environment pointer has unsafe type")
    generation = destination / ("generation-" + uuid.uuid4().hex)
    generation.mkdir(mode=0o700)
    link = destination / ("pending-" + uuid.uuid4().hex)
    published = False
    try:
        for service in SERVICES:
            path = generation / f"{service}.env"
            with path.open("x", encoding="utf-8", newline="\n") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(contents(values, service))
                stream.flush()
                os.fsync(stream.fileno())
        os.symlink(generation.name, link)
        os.replace(link, current)
        published = True
    finally:
        if link.is_symlink():
            link.unlink()
        if not published:
            shutil.rmtree(generation)
    # Only remove the checked, direct child previously named by our pointer.
    if previous is not None:
        shutil.rmtree(previous)
    check(values, destination, owner)


def check_container(values: dict[str, str], service: str, entries: object) -> None:
    require(service in {"app", "postgres", "minio", "livekit"}, "Unknown running service")
    require(isinstance(entries, list) and all(isinstance(entry, str) for entry in entries),
            "Container environment is unreadable")
    actual = {}
    for entry in entries:
        name, delimiter, value = entry.partition("=")
        require(delimiter == "=" and name not in actual, "Container environment has invalid or repeated inputs")
        actual[name] = value
    expected = {key: values[key] for key in SERVICES[service] if key in values}
    # The app Quadlet intentionally owns these launch settings, overriding source values.
    if service == "app":
        expected.update(K_COMMS_ROLE="all", K_COMMS_RUNTIME_PURPOSE="application",
                        K_COMMS_LOCAL_RELEASE="true", PORT="4000")
    require(not (set(actual) & (KNOWN_KEYS - SERVICES[service])),
            f"Container has another service's environment inputs: {service}")
    require(all(actual.get(key) == value for key, value in expected.items()),
            f"Container environment does not match its restricted source: {service}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--container", choices=("app", "postgres", "minio", "livekit"))
    args = parser.parse_args()
    try:
        require(os.geteuid() == 0, "Service environment operations require root")
        if args.check or args.container:
            values = parse_source(args.source)
            check(values, args.destination)
            if args.container:
                data = sys.stdin.read(256 * 1024 + 1)
                require(len(data) <= 256 * 1024, "Container environment exceeds its size limit")
                check_container(values, args.container, json.loads(data))
        else:
            generate(args.source, args.destination)
    except (EnvironmentError, OSError, UnicodeError, ValueError) as error:
        message = str(error) if isinstance(error, EnvironmentError) else "Service environment operation failed"
        raise SystemExit(message) from None


if __name__ == "__main__":
    main()
