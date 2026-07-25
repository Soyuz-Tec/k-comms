#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUALIFIER = ROOT / "scripts" / "qualify_local_release.ps1"
LIVE_GUEST_SPEC = ROOT / "clients" / "web" / "e2e" / "live-guest-communication.spec.ts"


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

    def test_requires_candidate_guest_links_capability(self) -> None:
        self.assertIn('"guest_links",', self.document)
        self.assertIn(
            "-Name $capability `\n"
            "            -Expected $true `\n"
            '            -Context "/api/v1/status capabilities"',
            self.document,
        )
        self.assertIn("guest_links = $true", self.document)

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

    def test_runs_real_guest_then_media_specs_serially(self) -> None:
        self.assertEqual(
            self.document.count('"e2e/live-guest-communication.spec.ts"'),
            1,
        )
        self.assertEqual(self.document.count('"e2e/live-audio.spec.ts"'), 1)
        self.assertEqual(self.document.count('"e2e/live-video.spec.ts"'), 1)
        self.assertEqual(self.document.count('"--workers=1"'), 2)
        self.assertIn('"K_COMMS_EXTERNAL_E2E_SERVER"', self.document)
        self.assertIn('"K_COMMS_LIVE_GUEST_E2E"', self.document)
        self.assertIn('"K_COMMS_LIVE_AUDIO_E2E"', self.document)
        self.assertIn('"K_COMMS_LIVE_VIDEO_E2E"', self.document)
        self.assertLess(
            self.document.index("Invoke-GuestSpec -Playwright $playwright"),
            self.document.index('Invoke-MediaSpec -Kind "audio" -Playwright $playwright'),
        )
        for forbidden_spec in (
            "e2e/accessibility.spec.ts",
            "e2e/mobile-ui.spec.ts",
            "e2e/member-ia.spec.ts",
            "e2e/smoke.spec.ts",
        ):
            self.assertNotIn(forbidden_spec, self.document)

    def test_live_guest_qualification_is_unmocked_and_covers_both_endings(self) -> None:
        specification = LIVE_GUEST_SPEC.read_text(encoding="utf-8")
        self.assertNotIn(".route(", specification)
        for route in (
            "/api/v1/guest-links/preview",
            "/api/v1/guest-sessions",
            "/api/v1/guest/conversation",
            "/api/v1/guest/socket-tickets",
            "/api/v1/guest/account",
            "/guest-links/",
        ):
            self.assertIn(route, specification)
        for expected in (
            "This guest link is unavailable",
            "This guest communication link is unavailable",
            "guest_account_conversion_email_mismatch",
            "verification_code: fixture.conversionVerificationCode",
            'account_type: "human"',
            "old guest credential after conversion",
        ):
            self.assertIn(expected, specification)
        for browser_journey_proof in (
            'getByRole("button", { name: "Invite guest" })',
            'getByRole("button", { name: "Create link and QR" })',
            'getByRole("textbox", { name: "Secure guest link" })',
            "not.toBeEditable()",
            '"data-qr-fingerprint"',
            "qrValueFingerprint(shareURL)",
            'getByRole("button", { name: "Close guest invitation" })',
            "navigateToGuestLink(guestPage, shareURL)",
            'window.location.hash === ""',
            '!window.location.href.includes("guest=")',
            'getByRole("textbox", { name: "Your display name" })',
            'getByRole("button", { name: "Join conversation" })',
        ):
            self.assertIn(browser_journey_proof, specification)
        for secret_bearing_failure_pattern in (
            "guestPage.evaluate(() => window.location.hash)",
            ".toHaveURL(",
        ):
            self.assertNotIn(secret_bearing_failure_pattern, specification)
        for secret_hygiene_proof in (
            'process.env.PLAYWRIGHT_NO_COPY_PROMPT = "1"',
            'test.use({ trace: "off", screenshot: "off", video: "off" })',
            'input.value = "[redacted secure guest link]"',
            '"guest-link navigation failed; URL redacted"',
            "revokeCreatedGuestLinks(",
            'not.toHaveAttribute("data-qr-value", /.+/)',
        ):
            self.assertIn(secret_hygiene_proof, specification)
        for strict_cleanup_proof in (
            "initialLinks = await listGuestLinksForCleanup(",
            "initialListFailureCount",
            "return response.status() === 200;",
            "verificationLinks = await listGuestLinksForCleanup(",
            "verificationListFailureCount",
            "failedDeleteCount",
            "remainingTrackedActiveCount",
        ):
            self.assertIn(strict_cleanup_proof, specification)


if __name__ == "__main__":
    unittest.main()
