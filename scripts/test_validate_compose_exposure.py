#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path

from validate_compose_exposure import EXPECTED_PORTS, validate_compose_exposure


ROOT = Path(__file__).resolve().parents[1]


def compose_document(ports: dict[str, list[str]]) -> str:
    lines = ["services:"]
    for service, values in ports.items():
        lines.extend(
            [
                f"  {service}:",
                "    image: example.invalid/test:latest",
                "    restart: unless-stopped",
                "    ports:",
            ]
        )
        lines.extend(f'      - "{value}"' for value in values)
    return "\n".join(lines) + "\n"


class ComposeExposurePolicyTest(unittest.TestCase):
    def test_repository_compose_file_passes(self) -> None:
        document = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertEqual(validate_compose_exposure(document), [])

    def test_broad_default_binding_fails(self) -> None:
        ports = {service: list(values) for service, values in EXPECTED_PORTS.items()}
        ports["app"] = [
            "${K_COMMS_BIND_ADDRESS:-0.0.0.0}:${APP_PORT:-4000}:4000"
        ]
        errors = validate_compose_exposure(compose_document(ports))
        self.assertTrue(any("service 'app' ports must be" in error for error in errors))

    def test_missing_host_binding_fails(self) -> None:
        ports = {service: list(values) for service, values in EXPECTED_PORTS.items()}
        ports["postgres"] = ["${POSTGRES_PORT:-5432}:5432"]
        errors = validate_compose_exposure(compose_document(ports))
        self.assertTrue(any("service 'postgres' ports must be" in error for error in errors))

    def test_livekit_media_ports_remain_loopback_bound(self) -> None:
        ports = {service: list(values) for service, values in EXPECTED_PORTS.items()}
        ports["livekit"][2] = (
            "${K_COMMS_BIND_ADDRESS:-0.0.0.0}:"
            "${LIVEKIT_UDP_PORT:-7882}:7882/udp"
        )
        errors = validate_compose_exposure(compose_document(ports))
        self.assertTrue(
            any("service 'livekit' ports must be" in error for error in errors)
        )

    def test_unclassified_published_service_fails(self) -> None:
        ports = {service: list(values) for service, values in EXPECTED_PORTS.items()}
        ports["debug"] = ["127.0.0.1:9999:9999"]
        errors = validate_compose_exposure(compose_document(ports))
        self.assertIn(
            "service 'debug' publishes unclassified host ports ['127.0.0.1:9999:9999']",
            errors,
        )

    def test_missing_restart_policy_fails(self) -> None:
        document = compose_document(EXPECTED_PORTS).replace(
            "  app:\n    image: example.invalid/test:latest\n"
            "    restart: unless-stopped\n",
            "  app:\n    image: example.invalid/test:latest\n",
        )
        errors = validate_compose_exposure(document)
        self.assertIn(
            "service 'app' restart policy must be 'unless-stopped'; observed None",
            errors,
        )

    def test_livekit_missing_restart_policy_fails(self) -> None:
        document = compose_document(EXPECTED_PORTS).replace(
            "  livekit:\n    image: example.invalid/test:latest\n"
            "    restart: unless-stopped\n",
            "  livekit:\n    image: example.invalid/test:latest\n",
        )
        errors = validate_compose_exposure(document)
        self.assertIn(
            "service 'livekit' restart policy must be 'unless-stopped'; observed None",
            errors,
        )

    def test_livekit_dev_mode_fails(self) -> None:
        document = compose_document(EXPECTED_PORTS).replace(
            "  livekit:\n    image: example.invalid/test:latest\n",
            "  livekit:\n    image: example.invalid/test:latest\n"
            "    command:\n      - --dev\n",
        )
        errors = validate_compose_exposure(document)
        self.assertIn(
            "service 'livekit' must not run with --dev because debug logs can "
            "expose participant credentials",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
