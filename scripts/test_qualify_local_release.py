#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUALIFIER = ROOT / "scripts" / "qualify_local_release.ps1"


class PackagedLocalReleaseQualifierTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = QUALIFIER.read_text(encoding="utf-8")

    def test_powershell_contract_self_test_passes(self) -> None:
        result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(QUALIFIER),
                "-SelfTest",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(
            result.returncode,
            0,
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertIn(
            "Packaged local release qualifier self-test passed.",
            result.stdout,
        )

    def test_targets_only_the_sealed_default_release(self) -> None:
        self.assertIn(
            '$script:BaseUri = "http://127.0.0.1:4188"',
            self.document,
        )
        self.assertIn('-Action Status', self.document)
        self.assertIn('-Action Status *>&1', self.document)
        self.assertIn(
            "Observed image matches receipt:\\s+True",
            self.document,
        )
        for path in (
            "/health/live",
            "/health/ready",
            "/api/v1/status",
            "/app/",
        ):
            self.assertIn(path, self.document)

    def test_requires_the_exact_packaged_csp(self) -> None:
        for directive in (
            "default-src 'self'",
            "frame-ancestors 'none'",
            "object-src 'none'",
            "script-src 'self'",
            "style-src 'self'",
            "ws://127.0.0.1:7980",
        ):
            self.assertIn(directive, self.document)
        self.assertIn(
            "$ContentSecurityPolicy -ceq $script:ExpectedContentSecurityPolicy",
            self.document,
        )

    def test_runs_only_real_media_specs_serially(self) -> None:
        self.assertEqual(self.document.count('"e2e/live-audio.spec.ts"'), 1)
        self.assertEqual(self.document.count('"e2e/live-video.spec.ts"'), 1)
        self.assertEqual(self.document.count('"--workers=1"'), 1)
        self.assertIn('"K_COMMS_EXTERNAL_E2E_SERVER"', self.document)
        self.assertIn('"K_COMMS_LIVE_AUDIO_E2E"', self.document)
        self.assertIn('"K_COMMS_LIVE_VIDEO_E2E"', self.document)
        for forbidden_spec in (
            "e2e/accessibility.spec.ts",
            "e2e/mobile-ui.spec.ts",
            "e2e/member-ia.spec.ts",
            "e2e/smoke.spec.ts",
        ):
            self.assertNotIn(forbidden_spec, self.document)


if __name__ == "__main__":
    unittest.main()
