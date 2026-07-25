#!/usr/bin/env python3

from __future__ import annotations

import copy
import unittest

from validate_staging_manifests import (
    ROOT,
    STAGING_CONFIG_PATCH,
    STAGING_MIGRATION_MANIFEST,
    STAGING_MINIO_MANIFEST,
    parse_binary_quantity,
    read_documents,
    validate,
    validate_documents,
)


class StagingManifestValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.documents = [
            *read_documents(ROOT / STAGING_CONFIG_PATCH),
            *read_documents(ROOT / STAGING_MINIO_MANIFEST),
            *read_documents(ROOT / STAGING_MIGRATION_MANIFEST),
        ]

    def test_repository_manifest_passes(self) -> None:
        self.assertEqual(validate(), [])

    def test_portable_staging_keeps_instant_rooms_fail_closed(self) -> None:
        config = self._config_map(self.documents)["data"]

        self.assertEqual(config["INSTANT_ROOMS_ENABLED"], "false")
        self.assertEqual(config["INSTANT_ROOM_TENANT_SLUG"], "")
        self.assertEqual(config["TRUSTED_PROXY_CIDRS"], "")

    def test_accepts_provider_composed_instant_room_ingress_contract(self) -> None:
        documents = self._provider_composed_documents()

        self.assertEqual(validate_documents(documents), [])

    def test_rejects_configuration_only_instant_room_enablement(self) -> None:
        documents = copy.deepcopy(self.documents)
        config = self._config_map(documents)["data"]
        config["INSTANT_ROOMS_ENABLED"] = "true"
        config["INSTANT_ROOM_TENANT_SLUG"] = "k-comms-staging"
        config["TRUSTED_PROXY_CIDRS"] = "203.0.113.64/28"

        errors = validate_documents(documents)

        self.assertTrue(
            any("require exactly one NetworkPolicy" in error for error in errors)
        )

    def test_rejects_broad_or_mismatched_trusted_proxy_ranges(self) -> None:
        documents = self._provider_composed_documents()
        config = self._config_map(documents)["data"]
        config["TRUSTED_PROXY_CIDRS"] = "10.0.0.0/8"

        errors = validate_documents(documents)

        self.assertTrue(
            any("not generic or unsafe networks" in error for error in errors)
        )
        self.assertTrue(
            any("must exactly match TRUSTED_PROXY_CIDRS" in error for error in errors)
        )

    def test_rejects_unrestricted_or_wrong_port_provider_ingress(self) -> None:
        documents = self._provider_composed_documents()
        policy = self._edge_ingress_policy(documents)
        policy["spec"]["ingress"][0].pop("from")
        policy["spec"]["ingress"][0]["ports"][0]["port"] = 80

        errors = validate_documents(documents)

        self.assertTrue(
            any("every source must be an explicit valid ipBlock" in error for error in errors)
        )
        self.assertTrue(
            any("only TCP port 4000" in error for error in errors)
        )

    def test_rejects_minio_tmp_below_two_gibibytes(self) -> None:
        documents = copy.deepcopy(self.documents)
        tmp = self._tmp_empty_dir(documents)
        tmp["sizeLimit"] = "2047Mi"

        errors = validate_documents(documents)

        self.assertTrue(any("at least 2Gi" in error for error in errors))

    def test_accepts_equivalent_two_gibibyte_quantity(self) -> None:
        documents = copy.deepcopy(self.documents)
        self._tmp_empty_dir(documents)["sizeLimit"] = "2048Mi"

        self.assertEqual(validate_documents(documents), [])
        self.assertEqual(parse_binary_quantity("2Gi"), parse_binary_quantity("2048Mi"))

    def test_rejects_missing_or_invalid_minio_tmp_limit(self) -> None:
        for invalid in (None, "", "2GB", 0, True):
            with self.subTest(invalid=invalid):
                documents = copy.deepcopy(self.documents)
                tmp = self._tmp_empty_dir(documents)
                if invalid is None:
                    tmp.pop("sizeLimit")
                else:
                    tmp["sizeLimit"] = invalid

                errors = validate_documents(documents)

                self.assertTrue(
                    any("valid sizeLimit" in error for error in errors), errors
                )

    def test_rejects_memory_backed_tmp(self) -> None:
        documents = copy.deepcopy(self.documents)
        self._tmp_empty_dir(documents)["medium"] = "Memory"

        errors = validate_documents(documents)

        self.assertTrue(any("node storage, not memory" in error for error in errors))

    def test_rejects_unwired_minio_tmp_mount(self) -> None:
        documents = copy.deepcopy(self.documents)
        statefulset = self._statefulset(documents)
        container = next(
            item
            for item in statefulset["spec"]["template"]["spec"]["containers"]
            if item["name"] == "minio"
        )
        next(
            item for item in container["volumeMounts"] if item["name"] == "tmp"
        )["mountPath"] = "/var/tmp"

        errors = validate_documents(documents)

        self.assertTrue(any("exactly once at /tmp" in error for error in errors))

    def test_rejects_blind_migration_retries(self) -> None:
        documents = copy.deepcopy(self.documents)
        self._migration_job(documents)["spec"]["backoffLimit"] = 1

        errors = validate_documents(documents)

        self.assertTrue(any("backoffLimit must be 0" in error for error in errors))

    def test_rejects_unbounded_or_non_quiescent_migration(self) -> None:
        documents = copy.deepcopy(self.documents)
        job = self._migration_job(documents)
        container = job["spec"]["template"]["spec"]["containers"][0]
        environment = {item["name"]: item for item in container["env"]}
        environment["K_COMMS_MIGRATION_REQUIRE_QUIESCENCE"]["value"] = "false"
        environment["K_COMMS_MIGRATION_LOCK_TIMEOUT_MS"]["value"] = "30001"
        environment["K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS"]["value"] = "600000"

        errors = validate_documents(documents)

        self.assertTrue(any("REQUIRE_QUIESCENCE must be true" in error for error in errors))
        self.assertTrue(any("LOCK_TIMEOUT_MS must be 1..30000" in error for error in errors))
        self.assertTrue(any("leave at least 30 seconds" in error for error in errors))

    def test_rejects_unreviewed_migration_runner(self) -> None:
        documents = copy.deepcopy(self.documents)
        container = self._migration_job(documents)["spec"]["template"]["spec"][
            "containers"
        ][0]
        container["args"] = ["eval", "System.halt(0)"]

        errors = validate_documents(documents)

        self.assertTrue(any("reviewed CommsCore.Release.migrate()" in error for error in errors))

    @staticmethod
    def _config_map(documents: list[object]) -> dict:
        return next(
            document
            for document in documents
            if isinstance(document, dict)
            and document.get("kind") == "ConfigMap"
            and document.get("metadata", {}).get("name") == "k-comms-config"
        )

    @staticmethod
    def _edge_ingress_policy(documents: list[object]) -> dict:
        return next(
            document
            for document in documents
            if isinstance(document, dict)
            and document.get("kind") == "NetworkPolicy"
            and document.get("metadata", {}).get("name") == "k-comms-edge-ingress"
        )

    @classmethod
    def _provider_composed_documents(cls) -> list[object]:
        documents = copy.deepcopy(cls.documents)
        config = cls._config_map(documents)["data"]
        config["INSTANT_ROOMS_ENABLED"] = "true"
        config["INSTANT_ROOM_TENANT_SLUG"] = "k-comms-staging"
        # RFC 5737 documentation range used only by this validator fixture.
        config["TRUSTED_PROXY_CIDRS"] = "203.0.113.64/28"
        documents.append(
            {
                "apiVersion": "networking.k8s.io/v1",
                "kind": "NetworkPolicy",
                "metadata": {"name": "k-comms-edge-ingress"},
                "spec": {
                    "ingress": [
                        {
                            "from": [
                                {"ipBlock": {"cidr": "203.0.113.64/28"}}
                            ],
                            "ports": [{"protocol": "TCP", "port": 4000}],
                        }
                    ]
                },
            }
        )
        return documents

    @staticmethod
    def _statefulset(documents: list[object]) -> dict:
        return next(
            document
            for document in documents
            if isinstance(document, dict)
            and document.get("kind") == "StatefulSet"
            and document.get("metadata", {}).get("name") == "minio"
        )

    @staticmethod
    def _migration_job(documents: list[object]) -> dict:
        return next(
            document
            for document in documents
            if isinstance(document, dict)
            and document.get("kind") == "Job"
            and document.get("metadata", {}).get("name") == "k-comms-migrate"
        )

    @classmethod
    def _tmp_empty_dir(cls, documents: list[object]) -> dict:
        statefulset = cls._statefulset(documents)
        volumes = statefulset["spec"]["template"]["spec"]["volumes"]
        return next(item for item in volumes if item["name"] == "tmp")["emptyDir"]


if __name__ == "__main__":
    unittest.main()
