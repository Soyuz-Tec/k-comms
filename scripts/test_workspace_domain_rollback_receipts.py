"""Execute the documented immutable-target metadata extractor with synthetic YAML."""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

from validate_production_bundle import (
    COMMUNICATION_ROLLBACK_CAPABILITIES,
    KNOWN_M1_ROLLBACK_CAPABILITIES,
    KNOWN_MEMBER_HISTORY_ROLLBACK_CAPABILITIES,
)

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "ghcr.io/soyuz-tec/k-comms@sha256:" + "a" * 64


class WorkspaceDomainRollbackReceiptTest(unittest.TestCase):
    def extract(self, edge: str | None, worker: str | None, worker_image: str = IMAGE):
        readme = (ROOT / "deploy/k8s/operations/guest-rollback-preflight/README.md").read_text()
        match = re.search(r'python - "\$TARGET_BUNDLE" <<\'PY\'\n(.*?)\nPY\n', readme, re.S)
        self.assertIsNotNone(match)
        documents = []
        for name, receipt, image in (("k-comms-edge", edge, IMAGE), ("k-comms-worker", worker, worker_image)):
            documents.append({"kind": "Deployment", "metadata": {"name": name},
                              "spec": {"template": {"metadata": {"annotations": {
                                  "k-comms.soyuz-tec.io/rollback-capabilities": receipt}},
                                  "spec": {"containers": [{"image": image}]}}}})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "target.yaml"
            path.write_text(yaml.safe_dump_all(documents))
            return subprocess.run([sys.executable, "-c", match[1], str(path)],
                                  capture_output=True, text=True, timeout=10)

    def test_actual_extractor_preserves_exact_m1_member_history_and_discovery_receipts(self):
        for receipt in (KNOWN_M1_ROLLBACK_CAPABILITIES, KNOWN_MEMBER_HISTORY_ROLLBACK_CAPABILITIES,
                        COMMUNICATION_ROLLBACK_CAPABILITIES):
            with self.subTest(receipt=receipt):
                result = self.extract(receipt, receipt)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.rstrip("\n").split("\t"), [IMAGE, "a" * 64, receipt])

    def test_actual_extractor_never_promotes_unknown_partial_mismatched_or_absent_receipts(self):
        for edge, worker in ((None, None), ("", ""), ("workspace_domain_discovery_v1", "workspace_domain_discovery_v1"),
                             (KNOWN_MEMBER_HISTORY_ROLLBACK_CAPABILITIES, COMMUNICATION_ROLLBACK_CAPABILITIES),
                             (COMMUNICATION_ROLLBACK_CAPABILITIES + ",unknown_v1", COMMUNICATION_ROLLBACK_CAPABILITIES + ",unknown_v1"),
                             (COMMUNICATION_ROLLBACK_CAPABILITIES + " ", COMMUNICATION_ROLLBACK_CAPABILITIES + " ")):
            with self.subTest(edge=edge, worker=worker):
                result = self.extract(edge, worker)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.rstrip("\n").split("\t"), [IMAGE, "a" * 64, ""])

    def test_actual_extractor_refuses_different_target_image_digests(self):
        result = self.extract(COMMUNICATION_ROLLBACK_CAPABILITIES, COMMUNICATION_ROLLBACK_CAPABILITIES,
                              IMAGE[:-64] + "b" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
