#!/usr/bin/env python3
"""Enforce local Compose exposure and restart-safety policies."""

from __future__ import annotations

import argparse
from pathlib import Path


EXPECTED_PORTS = {
    "postgres": [
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${POSTGRES_PORT:-5432}:5432",
    ],
    "minio": [
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${MINIO_PORT:-9000}:9000",
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${MINIO_CONSOLE_PORT:-9001}:9001",
    ],
    "livekit": [
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${LIVEKIT_SIGNAL_PORT:-7880}:7880/tcp",
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${LIVEKIT_TCP_PORT:-7881}:7881/tcp",
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${LIVEKIT_UDP_PORT:-7882}:7882/udp",
    ],
    "app": [
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${APP_PORT:-4000}:4000",
    ],
    "web": [
        "${K_COMMS_BIND_ADDRESS:-127.0.0.1}:${WEB_PORT:-5173}:5173",
    ],
}

EXPECTED_RESTART_POLICIES = {
    "postgres": "unless-stopped",
    "minio": "unless-stopped",
    "livekit": "unless-stopped",
    "app": "unless-stopped",
    "web": "unless-stopped",
}


def published_ports(document: str) -> dict[str, list[str]]:
    """Extract service port entries from the repository's simple Compose YAML."""

    result: dict[str, list[str]] = {}
    in_services = False
    service: str | None = None
    in_ports = False

    for raw_line in document.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent == 0:
            in_services = stripped == "services:"
            service = None
            in_ports = False
            continue
        if not in_services:
            continue
        if indent == 2 and stripped.endswith(":"):
            service = stripped[:-1]
            in_ports = False
            continue
        if service is None:
            continue
        if indent == 4:
            in_ports = stripped == "ports:"
            continue
        if in_ports and indent == 6 and stripped.startswith("- "):
            value = stripped[2:].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
                value = value[1:-1]
            result.setdefault(service, []).append(value)

    return result


def restart_policies(document: str) -> dict[str, str]:
    """Extract service restart policies from the repository's simple YAML."""

    result: dict[str, str] = {}
    in_services = False
    service: str | None = None

    for raw_line in document.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent == 0:
            in_services = stripped == "services:"
            service = None
            continue
        if not in_services:
            continue
        if indent == 2 and stripped.endswith(":"):
            service = stripped[:-1]
            continue
        if service is not None and indent == 4 and stripped.startswith("restart:"):
            value = stripped.split(":", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
                value = value[1:-1]
            result[service] = value

    return result


def validate_compose_exposure(document: str) -> list[str]:
    actual = published_ports(document)
    errors: list[str] = []

    for service, expected in EXPECTED_PORTS.items():
        observed = actual.pop(service, [])
        if observed != expected:
            errors.append(
                f"service {service!r} ports must be {expected!r}; observed {observed!r}"
            )

    for service, observed in sorted(actual.items()):
        errors.append(
            f"service {service!r} publishes unclassified host ports {observed!r}"
        )

    restart_actual = restart_policies(document)
    for service, expected in EXPECTED_RESTART_POLICIES.items():
        observed = restart_actual.get(service)
        if observed != expected:
            errors.append(
                f"service {service!r} restart policy must be {expected!r}; "
                f"observed {observed!r}"
            )

    if "\n      - --dev\n" in document:
        errors.append(
            "service 'livekit' must not run with --dev because debug logs can "
            "expose participant credentials"
        )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate local Compose exposure and restart-safety policies."
    )
    parser.add_argument("path", nargs="?", default="compose.yaml", type=Path)
    arguments = parser.parse_args()
    errors = validate_compose_exposure(arguments.path.read_text(encoding="utf-8"))
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"Compose exposure policy passed: {arguments.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
