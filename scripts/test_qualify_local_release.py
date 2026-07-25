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
        for base_uri in (
            "http://127.0.0.1:4188",
            "http://192.168.50.12:4188",
            "http://192.168.50.12:4288",
        ):
            with self.subTest(base_uri=base_uri):
                arguments = [
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(QUALIFIER),
                    "-SelfTest",
                    "-BaseUri",
                    base_uri,
                ]
                if not base_uri.startswith("http://127."):
                    arguments.append("-LanTextOnly")
                result = subprocess.run(
                    arguments,
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

    def test_lan_text_only_mode_is_explicit_and_never_allowed_on_loopback(
        self,
    ) -> None:
        lan_result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(QUALIFIER),
                "-SelfTest",
                "-LanTextOnly",
                "-BaseUri",
                "http://192.168.50.12:4188",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(
            lan_result.returncode,
            0,
            f"stdout:\n{lan_result.stdout}\nstderr:\n{lan_result.stderr}",
        )

        loopback_result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(QUALIFIER),
                "-SelfTest",
                "-LanTextOnly",
                "-BaseUri",
                "http://127.0.0.1:4188",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertNotEqual(loopback_result.returncode, 0)
        self.assertIn(
            "-LanTextOnly is valid only for a non-loopback RFC1918 BaseUri",
            loopback_result.stderr,
        )

        lan_media_result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(QUALIFIER),
                "-SelfTest",
                "-BaseUri",
                "http://192.168.50.12:4188",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertNotEqual(lan_media_result.returncode, 0)
        self.assertIn(
            "Plain HTTP RFC1918 qualification requires -LanTextOnly",
            lan_media_result.stderr,
        )

    def test_targets_an_operator_selected_private_origin_with_loopback_default(
        self,
    ) -> None:
        self.assertIn(
            '[string]$BaseUri = "http://127.0.0.1:4188"',
            self.document,
        )
        self.assertIn("Resolve-SealedBaseUri -Value $BaseUri", self.document)
        self.assertIn("RFC1918 private space", self.document)
        self.assertIn("no credentials, path, query, or fragment", self.document)
        self.assertIn("-Action Status", self.document)
        self.assertIn("-Action Status *>&1", self.document)
        self.assertIn(
            "Observed image matches receipt:\\s+True",
            self.document,
        )
        self.assertIn(
            "Observed network topology matches receipt:\\s+True",
            self.document,
        )
        self.assertIn(
            '$expectedApplicationUri = "$($target.AppOrigin)/app/"',
            self.document,
        )
        self.assertIn('"publicAppUrl"', self.document)
        self.assertIn('"^PUBLIC_APP_URL="', self.document)
        self.assertIn(
            "does not match sealed release origin",
            self.document,
        )
        self.assertIn('"network"', self.document)
        self.assertIn('"bindAddress"', self.document)
        self.assertIn('"publicHost"', self.document)
        self.assertIn('"podmanBindAddress"', self.document)
        self.assertIn('"exposureMode"', self.document)
        self.assertIn('"lan-forwarder"', self.document)
        self.assertIn("network publicAppUrl must be", self.document)
        for path in (
            "/health/live",
            "/health/ready",
            "/api/v1/status",
            "/app/",
        ):
            self.assertIn(path, self.document)

    def test_requires_current_forwarder_identity_readiness_and_hash_for_lan(
        self,
    ) -> None:
        for contract in (
            '"forwarder"',
            '"required"',
            '"scriptPath"',
            '"scriptSha256"',
            '"configPath"',
            '"configSha256"',
            '"statusPath"',
            '"readinessToken"',
            '"listeners"',
            "Forwarder:\\s+ready",
            "Observed forwarder matches receipt:\\s+True",
            "Observed forwarder configuration hash matches receipt:\\s+True",
            "Forwarder:\\s+not-required",
        ):
            self.assertIn(contract, self.document)
        self.assertIn("Assert-ForwarderStatusContract", self.document)
        self.assertIn("schema-v3/v4 sealed release receipts", self.document)
        self.assertIn("private-LAN qualification requires a schema-v5", self.document)

    def test_requires_candidate_guest_links_capability(self) -> None:
        self.assertIn('"guest_links",', self.document)
        self.assertIn(
            "-Name $capability `\n"
            "            -Expected $true `\n"
            '            -Context "/api/v1/status capabilities"',
            self.document,
        )
        self.assertIn("guest_links = $true", self.document)

    def test_requires_and_probes_the_instant_room_capability(self) -> None:
        self.assertIn('"instant_rooms",', self.document)
        self.assertIn("instant_rooms = $true", self.document)
        self.assertIn(
            "Invoke-InstantRoomEndpointCheck",
            self.document,
        )
        self.assertIn(
            '"/api/v1/instant-rooms/preview"',
            self.document,
        )
        self.assertIn(
            "-Headers @{Origin = $script:BaseUri}",
            self.document,
        )
        self.assertIn(
            '-Expected "instant_room_unavailable"',
            self.document,
        )

    def test_requires_the_exact_packaged_csp(self) -> None:
        for directive in (
            "default-src 'self'",
            "frame-ancestors 'none'",
            "object-src 'none'",
            "script-src 'self'",
            "style-src 'self'",
            "$AppOrigin",
            "$AppWebSocketOrigin",
            "$LiveKitOrigin",
            "$MinioOrigin",
        ):
            self.assertIn(directive, self.document)
        self.assertIn(
            "Get-RequiredReceiptPort -Ports $ports -Name \"livekitSignal\"",
            self.document,
        )
        self.assertIn(
            "Get-RequiredReceiptPort -Ports $ports -Name \"livekitTcp\"",
            self.document,
        )
        self.assertIn(
            "Get-RequiredReceiptPort -Ports $ports -Name \"livekitUdp\"",
            self.document,
        )
        self.assertIn(
            "Get-RequiredReceiptPort -Ports $ports -Name \"minio\"",
            self.document,
        )
        self.assertIn(
            "-LiveKitOrigin $target.LiveKitOrigin",
            self.document,
        )
        self.assertIn(
            "-MinioOrigin $target.MinioOrigin",
            self.document,
        )
        self.assertNotIn("-Expected 7980", self.document)
        self.assertNotIn("-Expected 5900", self.document)
        self.assertIn(
            "$ContentSecurityPolicy -ceq $script:ExpectedContentSecurityPolicy",
            self.document,
        )

    def test_self_test_covers_receipt_port_overrides(self) -> None:
        for contract in (
            "app = 4288",
            "livekitSignal = 8980",
            "livekitTcp = 8981",
            "livekitUdp = 8982",
            "minio = 6900",
            "ws://192.168.50.12:8980",
            "http://192.168.50.12:6900",
            "Self-test CSP retained hard-coded default source",
            "five-listener application/object/media contract",
            'targetHost = "127.0.0.1"',
        ):
            self.assertIn(contract, self.document)

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
        self.assertIn("[switch]$LanTextOnly", self.document)
        self.assertIn(
            "if ($script:QualificationMode.LanTextOnly)",
            self.document,
        )
        self.assertIn(
            "Media was NOT qualified for this release origin.",
            self.document,
        )
        self.assertIn(
            "Audio and video media were NOT qualified.",
            self.document,
        )
        self.assertIn(
            "Plain HTTP RFC1918 qualification requires -LanTextOnly",
            self.document,
        )
        self.assertIn(
            "audio and video media cannot be qualified or claimed",
            self.document,
        )
        self.assertIn(
            "including audio and video media.",
            self.document,
        )
        for base_url_variable in (
            "K_COMMS_E2E_BASE_URL",
            "K_COMMS_LIVE_GUEST_BASE_URL",
            "K_COMMS_LIVE_AUDIO_BASE_URL",
            "K_COMMS_LIVE_VIDEO_BASE_URL",
        ):
            self.assertRegex(
                self.document,
                rf'"{base_url_variable}",\s+\$script:BaseUri,\s+"Process"',
            )
        self.assertLess(
            self.document.index("Invoke-GuestSpec -Playwright $playwright"),
            self.document.index(
                'Invoke-MediaSpec -Kind "audio" -Playwright $playwright'
            ),
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
            "This communication link is unavailable",
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
