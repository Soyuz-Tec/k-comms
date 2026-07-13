from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

from validate_production_bundle import validate, validate_documents


VAPID_PUBLIC_KEY = "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
DIGEST_IMAGE = "ghcr.io/soyuz-tec/k-comms@sha256:" + "a" * 64


class ValidateProductionBundleTest(unittest.TestCase):
    def test_accepts_a_fully_composed_provider_bundle(self) -> None:
        self.assertEqual(validate_documents(valid_documents()), [])

    def test_rejects_fail_closed_defaults_placeholders_and_mutable_images(self) -> None:
        documents = valid_documents()
        config = documents[0]["data"]
        config.update(
            {
                "PHX_HOST": "comms.example.invalid",
                "PUBLIC_APP_URL": "https://comms.example.invalid",
                "NOTIFICATION_PROVIDER_MODE": "disabled",
                "ATTACHMENT_SCANNER_MODE": "disabled",
                "WEBHOOK_PROVIDER_MODE": "disabled",
                "WEB_PUSH_VAPID_PUBLIC_KEY": "",
            }
        )
        documents[1]["spec"]["template"]["spec"]["containers"][0]["image"] = (
            "ghcr.io/soyuz-tec/k-comms:production-candidate"
        )
        documents[4]["spec"]["egress"][0]["to"][0]["ipBlock"]["cidr"] = "0.0.0.0/0"

        errors = validate_documents(documents)
        self.assertTrue(
            any("NOTIFICATION_PROVIDER_MODE must be http" in error for error in errors)
        )
        self.assertTrue(
            any(
                "PHX_HOST is missing or still a placeholder" in error
                for error in errors
            )
        )
        self.assertTrue(any("immutable sha256 digest" in error for error in errors))
        self.assertTrue(
            any("database CIDR must be narrowed" in error for error in errors)
        )

    def test_rejects_provider_endpoint_not_present_in_the_allowlist(self) -> None:
        documents = valid_documents()
        documents[0]["data"]["NOTIFICATION_PROVIDER_ENDPOINT"] = (
            "https://unapproved.example.com/v1/deliver"
        )

        errors = validate_documents(documents)
        self.assertTrue(
            any(
                "NOTIFICATION_PROVIDER_ENDPOINT host must be present" in error
                for error in errors
            )
        )

    def test_rejects_provider_preflight_bypass_on_long_lived_workloads(self) -> None:
        documents = valid_documents()
        documents[1]["spec"]["template"]["spec"]["containers"][0]["env"] = [
            {"name": "K_COMMS_RUNTIME_PURPOSE", "value": "one_shot"}
        ]

        errors = validate_documents(documents)
        self.assertTrue(
            any(
                "Deployment k-comms-edge: K_COMMS_RUNTIME_PURPOSE must be application"
                in error
                for error in errors
            )
        )

    def test_rejects_broad_or_mismatched_trusted_proxy_ingress(self) -> None:
        documents = valid_documents()
        documents[0]["data"]["TRUSTED_PROXY_CIDRS"] = "10.0.0.0/8"

        errors = validate_documents(documents)
        self.assertTrue(
            any("must not trust generic or unsafe ranges" in error for error in errors)
        )
        self.assertTrue(
            any("must exactly match TRUSTED_PROXY_CIDRS" in error for error in errors)
        )

        documents = valid_documents()
        edge_policy = next(
            document
            for document in documents
            if document.get("kind") == "NetworkPolicy"
            and document.get("metadata", {}).get("name") == "k-comms-edge-ingress"
        )
        edge_policy["spec"]["ingress"] = [{"ports": [{"port": 4000}]}]

        errors = validate_documents(documents)
        self.assertTrue(
            any(
                "every source must be an explicit valid ipBlock" in error
                for error in errors
            )
        )

    def test_rejects_split_ranges_that_collectively_cover_private_defaults(
        self,
    ) -> None:
        split_private_defaults = (
            ("10.0.0.0/9", "10.128.0.0/9"),
            ("172.16.0.0/13", "172.24.0.0/13"),
            ("192.168.0.0/17", "192.168.128.0/17"),
        )

        for cidrs in split_private_defaults:
            with self.subTest(cidrs=cidrs):
                documents = valid_documents()
                set_trusted_proxy_cidrs(documents, cidrs)

                errors = validate_documents(documents)

                self.assertTrue(
                    any(
                        "must not trust generic or unsafe ranges" in error
                        for error in errors
                    )
                )
                self.assertFalse(
                    any(
                        "must exactly match TRUSTED_PROXY_CIDRS" in error
                        for error in errors
                    )
                )

    def test_accepts_adjacent_narrow_provider_specific_proxy_ranges(self) -> None:
        documents = valid_documents()
        set_trusted_proxy_cidrs(documents, ("10.42.6.0/24", "10.42.7.0/24"))

        self.assertEqual(validate_documents(documents), [])

    def test_rejects_missing_or_inexact_edge_ingress_ports(self) -> None:
        invalid_ports = (
            None,
            ["TCP/4000"],
            [{"protocol": "UDP", "port": 4000}],
            [{"protocol": "TCP", "port": 9090}],
            [{"protocol": "TCP", "port": 4000, "endPort": 4001}],
        )

        for ports in invalid_ports:
            with self.subTest(ports=ports):
                documents = valid_documents()
                edge_policy = next(
                    document
                    for document in documents
                    if document.get("kind") == "NetworkPolicy"
                    and document.get("metadata", {}).get("name")
                    == "k-comms-edge-ingress"
                )
                if ports is None:
                    edge_policy["spec"]["ingress"][0].pop("ports")
                else:
                    edge_policy["spec"]["ingress"][0]["ports"] = ports

                errors = validate_documents(documents)

                self.assertTrue(
                    any(
                        "every ingress rule must expose only TCP port 4000" in error
                        for error in errors
                    )
                )

    def test_reads_multi_document_yaml_without_exposing_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "production.yaml"
            documents = valid_documents()
            documents[0]["data"]["ATTACHMENT_SCANNER_ENDPOINT"] = "private-sentinel"
            path.write_text(
                "---\n".join(yaml.safe_dump(document) for document in documents),
                encoding="utf-8",
            )

            errors = validate(path)
            self.assertTrue(errors)
            self.assertNotIn("private-sentinel", "\n".join(errors))


def valid_documents() -> list[dict]:
    config = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": "k-comms-config"},
        "data": {
            "ALLOW_BOOTSTRAP": "false",
            "ALLOW_DEVELOPMENT_ADAPTERS": "false",
            "DATABASE_SSL": "true",
            "HSTS_ENABLED": "true",
            "PHX_HOST": "comms.example.com",
            "PUBLIC_APP_URL": "https://comms.example.com",
            "CORS_ORIGINS": "https://comms.example.com",
            "S3_PUBLIC_ENDPOINT": "https://objects.example.com",
            "S3_INTERNAL_ENDPOINT": "https://objects.example.com",
            "S3_BUCKET": "k-comms-production",
            "NOTIFICATION_PROVIDER_MODE": "http",
            "NOTIFICATION_PROVIDER_ENDPOINT": "https://notifications.example.com/v1/deliver",
            "NOTIFICATION_PROVIDER_NAME": "approved-notifications",
            "NOTIFICATION_PROVIDER_ALLOWED_HOSTS": "notifications.example.com",
            "ATTACHMENT_SCANNER_MODE": "http",
            "ATTACHMENT_SCANNER_ENDPOINT": "https://scanner.example.com/v1/scan",
            "ATTACHMENT_SCANNER_PROVIDER_NAME": "approved-scanner",
            "ATTACHMENT_SCANNER_ALLOWED_HOSTS": "scanner.example.com",
            "WEBHOOK_PROVIDER_MODE": "http",
            "WEBHOOK_ALLOWED_HOSTS": "hooks.customer.example.com",
            "WEB_PUSH_VAPID_PUBLIC_KEY": VAPID_PUBLIC_KEY,
            "TRUSTED_PROXY_CIDRS": "10.42.7.0/24",
        },
    }
    return [
        config,
        workload("Deployment", "k-comms-edge"),
        workload("Deployment", "k-comms-worker"),
        workload("Job", "k-comms-migrate"),
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {"name": "k-comms-managed-postgres-egress"},
            "spec": {
                "egress": [
                    {
                        "to": [{"ipBlock": {"cidr": "10.42.0.0/24"}}],
                        "ports": [{"port": 5432}],
                    }
                ]
            },
        },
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {"name": "k-comms-edge-ingress"},
            "spec": {
                "ingress": [
                    {
                        "from": [{"ipBlock": {"cidr": "10.42.7.0/24"}}],
                        "ports": [{"protocol": "TCP", "port": 4000}],
                    }
                ]
            },
        },
    ]


def workload(kind: str, name: str) -> dict:
    environment = []
    if kind == "Job":
        environment.append({"name": "K_COMMS_RUNTIME_PURPOSE", "value": "one_shot"})

    return {
        "apiVersion": "apps/v1" if kind == "Deployment" else "batch/v1",
        "kind": kind,
        "metadata": {"name": name},
        "spec": {
            "template": {
                "spec": {
                    "containers": [
                        {"name": name, "image": DIGEST_IMAGE, "env": environment}
                    ]
                }
            }
        },
    }


def set_trusted_proxy_cidrs(documents: list[dict], cidrs: tuple[str, ...]) -> None:
    documents[0]["data"]["TRUSTED_PROXY_CIDRS"] = ",".join(cidrs)
    edge_policy = next(
        document
        for document in documents
        if document.get("kind") == "NetworkPolicy"
        and document.get("metadata", {}).get("name") == "k-comms-edge-ingress"
    )
    edge_policy["spec"]["ingress"] = [
        {
            "from": [{"ipBlock": {"cidr": cidr}} for cidr in cidrs],
            "ports": [{"protocol": "TCP", "port": 4000}],
        }
    ]


if __name__ == "__main__":
    unittest.main()
