#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path

from validate_compose_exposure import EXPECTED_PORTS, validate_compose_exposure


ROOT = Path(__file__).resolve().parents[1]


def compose_document(ports: dict[str, list[str]]) -> str:
    lines = ["services:"]
    for service, values in ports.items():
        lines.extend([f"  {service}:", "    image: example.invalid/test:latest", "    ports:"])
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

    def test_unclassified_published_service_fails(self) -> None:
        ports = {service: list(values) for service, values in EXPECTED_PORTS.items()}
        ports["debug"] = ["127.0.0.1:9999:9999"]
        errors = validate_compose_exposure(compose_document(ports))
        self.assertIn(
            "service 'debug' publishes unclassified host ports ['127.0.0.1:9999:9999']",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
