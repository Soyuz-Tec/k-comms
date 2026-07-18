#!/usr/bin/env python3

from __future__ import annotations

import copy
import unittest

from validate_staging_manifests import (
    ROOT,
    STAGING_MINIO_MANIFEST,
    parse_binary_quantity,
    read_documents,
    validate,
    validate_documents,
)


class StagingManifestValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.documents = read_documents(ROOT / STAGING_MINIO_MANIFEST)

    def test_repository_manifest_passes(self) -> None:
        self.assertEqual(validate(), [])

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

    @staticmethod
    def _statefulset(documents: list[object]) -> dict:
        return next(
            document
            for document in documents
            if isinstance(document, dict)
            and document.get("kind") == "StatefulSet"
            and document.get("metadata", {}).get("name") == "minio"
        )

    @classmethod
    def _tmp_empty_dir(cls, documents: list[object]) -> dict:
        statefulset = cls._statefulset(documents)
        volumes = statefulset["spec"]["template"]["spec"]["volumes"]
        return next(item for item in volumes if item["name"] == "tmp")["emptyDir"]


if __name__ == "__main__":
    unittest.main()
