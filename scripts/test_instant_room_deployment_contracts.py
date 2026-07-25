#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
K8S = ROOT / "deploy" / "k8s"
ROLLBACK_CAPABILITIES = (
    "guest_identity_v1,"
    "guest_admission_expiry_worker_v1,"
    "instant_room_lifecycle_v1,"
    "instant_room_presence_lease_v1,"
    "instant_room_expiry_worker_v1,"
    "conversation_only_human_v1"
)
LIFECYCLE_VALUES = {
    "INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS": "3600",
    "INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS": "86400",
    "INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS": "30",
    "INSTANT_ROOM_PRESENCE_LEASE_SECONDS": "90",
    "INSTANT_ROOM_RECONNECT_GRACE_SECONDS": "90",
    "INSTANT_ROOM_MAX_PARTICIPANTS": "25",
}


def load_yaml(path: Path) -> dict:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise TypeError(f"{path} must contain one YAML mapping")
    return document


def load_yamls(path: Path) -> list[dict]:
    documents = [
        document
        for document in yaml.safe_load_all(path.read_text(encoding="utf-8"))
        if isinstance(document, dict)
    ]
    if not documents:
        raise TypeError(f"{path} must contain YAML mappings")
    return documents


class InstantRoomDeploymentContractTest(unittest.TestCase):
    def test_edge_and_worker_publish_identical_rollback_capabilities(self) -> None:
        for name in ("edge-deployment.yaml", "worker-deployment.yaml"):
            deployment = load_yaml(K8S / "base" / name)
            annotations = deployment["spec"]["template"]["metadata"]["annotations"]
            self.assertEqual(
                annotations["k-comms.soyuz-tec.io/rollback-capabilities"],
                ROLLBACK_CAPABILITIES,
            )

    def test_environment_profiles_are_explicit_and_production_fails_closed(
        self,
    ) -> None:
        base = load_yaml(K8S / "base" / "configmap.yaml")["data"]
        staging = load_yaml(K8S / "overlays" / "staging" / "configmap-patch.yaml")[
            "data"
        ]
        production = load_yaml(
            K8S / "overlays" / "production" / "configmap-patch.yaml"
        )["data"]

        self.assertEqual(base["INSTANT_ROOMS_ENABLED"], "false")
        self.assertEqual(base["INSTANT_ROOM_TENANT_SLUG"], "")
        self.assertEqual(staging["INSTANT_ROOMS_ENABLED"], "false")
        self.assertEqual(staging["INSTANT_ROOM_TENANT_SLUG"], "")
        self.assertEqual(staging["TRUSTED_PROXY_CIDRS"], "")
        self.assertEqual(production["INSTANT_ROOMS_ENABLED"], "false")
        self.assertEqual(production["INSTANT_ROOM_TENANT_SLUG"], "")
        for name, expected in LIFECYCLE_VALUES.items():
            self.assertEqual(base[name], expected)
            self.assertEqual(staging[name], expected)
            self.assertEqual(production[name], expected)

        bootstrap_example = (
            K8S / "overlays" / "staging" / "bootstrap-secrets.env.example"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "BOOTSTRAP_TENANT_SLUG=k-comms-staging",
            bootstrap_example,
        )

    def test_staging_provider_patch_couples_enablement_to_exact_ingress_sources(
        self,
    ) -> None:
        staging_root = K8S / "overlays" / "staging"
        example_name = "instant-rooms-provider-patch.example.yaml"
        documents = load_yamls(staging_root / example_name)
        config = next(
            document
            for document in documents
            if document.get("kind") == "ConfigMap"
        )["data"]
        policy = next(
            document
            for document in documents
            if document.get("kind") == "NetworkPolicy"
        )
        placeholder = "REPLACE_WITH_EXACT_INGRESS_CIDR"

        self.assertEqual(config["INSTANT_ROOMS_ENABLED"], "true")
        self.assertEqual(config["INSTANT_ROOM_TENANT_SLUG"], "k-comms-staging")
        self.assertEqual(config["TRUSTED_PROXY_CIDRS"], placeholder)
        self.assertEqual(
            policy["spec"]["ingress"][0]["from"][0]["ipBlock"]["cidr"],
            placeholder,
        )
        self.assertNotIn(
            example_name,
            [
                patch.get("path") if isinstance(patch, dict) else patch
                for patch in load_yaml(staging_root / "kustomization.yaml").get(
                    "patches", []
                )
            ],
        )

    def test_local_immutable_release_keeps_instant_rooms_enabled(self) -> None:
        compose = load_yaml(ROOT / "deploy" / "compose.local-release.yaml")
        environment = compose["x-release-environment"]

        self.assertEqual(environment["INSTANT_ROOMS_ENABLED"], "${INSTANT_ROOMS_ENABLED:-true}")
        self.assertEqual(
            environment["INSTANT_ROOM_TENANT_SLUG"],
            "${INSTANT_ROOM_TENANT_SLUG:-k-comms-development}",
        )

    def test_public_admission_paths_are_rate_limited_in_both_overlays(
        self,
    ) -> None:
        required_paths = {
            "/api/v1/instant-rooms",
            "/api/v1/instant-room-sessions",
            "/api/v1/guest-links/preview",
            "/api/v1/guest-sessions",
            "/api/v1/guest",
        }

        for overlay in ("staging", "production"):
            kustomization = load_yaml(K8S / "overlays" / overlay / "kustomization.yaml")
            self.assertIn(
                "public-admission-rate-limit-ingress.yaml",
                kustomization["resources"],
            )

            ingress = load_yaml(
                K8S / "overlays" / overlay / "public-admission-rate-limit-ingress.yaml"
            )
            annotations = ingress["metadata"]["annotations"]
            self.assertEqual(
                annotations["nginx.ingress.kubernetes.io/limit-rps"],
                "5",
            )
            self.assertEqual(
                annotations["nginx.ingress.kubernetes.io/limit-connections"],
                "10",
            )
            observed_paths = {
                item["path"]
                for rule in ingress["spec"]["rules"]
                for item in rule["http"]["paths"]
            }
            self.assertEqual(observed_paths, required_paths)

    def test_one_shot_operation_uses_the_combined_rollback_gate(self) -> None:
        job = load_yaml(
            K8S
            / "operations"
            / "guest-rollback-preflight"
            / "guest-rollback-preflight-job.yaml"
        )
        container = job["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(
            container["args"],
            [
                "eval",
                "CommsCore.Release.assert_communication_rollback_compatible!()",
            ],
        )
        self.assertIn("@sha256:", container["image"])


if __name__ == "__main__":
    unittest.main()
