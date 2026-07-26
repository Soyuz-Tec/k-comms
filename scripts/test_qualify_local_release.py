#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path

from validate_local_release import _function_body

ROOT = Path(__file__).resolve().parents[1]
QUALIFIER = ROOT / "scripts" / "qualify_local_release.ps1"
LIVE_INSTANT_ROOM_SPEC = (
    ROOT / "clients" / "web" / "e2e" / "live-instant-room.spec.ts"
)
LIVE_GUEST_SPEC = ROOT / "clients" / "web" / "e2e" / "live-guest-communication.spec.ts"
LIVE_AUDIO_SPEC = ROOT / "clients" / "web" / "e2e" / "live-audio.spec.ts"
LIVE_VIDEO_SPEC = ROOT / "clients" / "web" / "e2e" / "live-video.spec.ts"
WINDOWS_POWERSHELL = shutil.which("powershell.exe")


class PackagedLocalReleaseQualifierTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = QUALIFIER.read_text(encoding="utf-8")

    @unittest.skipUnless(
        os.name == "nt",
        "packaged PowerShell execution is covered by the Windows CI job",
    )
    def test_powershell_contract_self_test_passes(self) -> None:
        for base_uri in (
            "http://127.0.0.1:4188",
            "http://192.168.50.12:4188",
            "http://192.168.50.12:4288",
            "https://comms.avayaworks.com",
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
                if base_uri.startswith("http://192.168."):
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

    @unittest.skipUnless(
        os.name == "nt",
        "packaged PowerShell execution is covered by the Windows CI job",
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

    def test_podman_progress_stderr_is_captured_by_native_exit_code(self) -> None:
        for proof in (
            "function Invoke-QualificationNativeCommand",
            '$ErrorActionPreference = "Continue"',
            "& $resolvedCommand.Source @ArgumentList 2>&1",
            "$exitCode = $global:LASTEXITCODE",
            "$ErrorActionPreference = $previousErrorActionPreference",
            "Native command executable is unavailable",
            "function Assert-NativeCommandCaptureSelfTest",
            "Assert-NativeCommandCaptureSelfTest",
            "k-comms-native-progress",
            "k-comms-native-failure",
        ):
            self.assertIn(proof, self.document)

        self.assertEqual(
            self.document.count("Invoke-QualificationNativeCommand `"),
            13,
        )
        self.assertEqual(self.document.count('-FilePath "podman"'), 11)
        self.assertNotIn("& podman", self.document)
        self.assertNotIn("qualification eval $expression 2>&1", self.document)
        self.assertNotIn("2>$null", self.document)
        self.assertNotIn("*>$null", self.document)

    @unittest.skipUnless(
        WINDOWS_POWERSHELL,
        "native command fail-closed execution is covered on Windows",
    )
    def test_native_helper_rejects_missing_executable_with_stale_zero(self) -> None:
        helper = (
            "function Invoke-QualificationNativeCommand {"
            + _function_body(
                self.document,
                "Invoke-QualificationNativeCommand",
            )
        )
        script = (
            '$ErrorActionPreference = "Continue"\n'
            + helper
            + "\n"
            + "$global:LASTEXITCODE = 0\n"
            + "$result = Invoke-QualificationNativeCommand "
            + "-FilePath 'k_comms_missing_native_command_xyz' "
            + "-ArgumentList @('--version')\n"
            + "if ($result.ExitCode -ne -1) { exit 9 }\n"
            + "if ($global:LASTEXITCODE -ne 0) { exit 10 }\n"
        )
        result = subprocess.run(
            [
                WINDOWS_POWERSHELL,
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                script,
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

    def test_requires_public_bootstrap_to_be_disabled(self) -> None:
        self.assertIn('-Name "bootstrap" `', self.document)
        self.assertIn("-Expected $false `", self.document)
        self.assertIn("bootstrap = $false", self.document)

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

    def test_trusted_edge_receipt_and_https_media_path_are_qualified(self) -> None:
        for proof in (
            "function Assert-TrustedEdgeQualificationSelfTest",
            "Assert-TrustedEdgeQualificationSelfTest",
            "schemaVersion = 7",
            "schema-v6 trusted-edge receipts trusted the Podman gateway",
            'exposureProfile = "cloudflare_trusted_edge"',
            'trustedEdgeConfirmation = "cloudflare-tunnel-v1"',
            'trustedProxyCidr = "10.89.0.254/32"',
            'trustedProxySourceKind = "podman-app-self-v1"',
            'applicationNetworkName = "k-comms-release_default"',
            'applicationNetworkSubnet = "10.89.0.0/24"',
            'applicationNetworkGateway = "10.89.0.1"',
            'applicationContainerIpv4 = "10.89.0.254"',
            'applicationContainerIpv4Cidr = "10.89.0.254/32"',
            'profile = "media-only"',
            "Trusted-edge forwarder must contain exactly two media listeners",
            "Test-QualificationRfc1918IPv4",
            "Strict-Transport-Security",
            "max-age=31536000; includeSubDomains",
            '"secure_account_actions"',
            '"secure_media_actions"',
            "Self-test accepted trusted-edge tamper",
            "Invoke-LanSecureTransportBoundaryCheck",
            "$script:LiveProvisionBaseUri",
        ):
            self.assertIn(proof, self.document)

        isolated_environment = self.document[
            self.document.index("function New-LiveQualificationAppEnvironment") :
            self.document.index("function Get-LiveQualificationAppInspection")
        ]
        for exact_clear in (
            'K_COMMS_RELEASE_EXPOSURE_MODE = ""',
            'K_COMMS_TRUSTED_EDGE_CONFIRMATION = ""',
            'K_COMMS_RELEASE_HOST = "127.0.0.1"',
            "PUBLIC_APP_URL = $retainedAppOrigin",
            "[string]$CleanupContext.PublicAppUrl",
            "K_COMMS_QUALIFICATION_SHARE_ORIGIN",
        ):
            self.assertIn(exact_clear, isolated_environment)

        qualification = self.document[
            self.document.index("function Invoke-PackagedReleaseQualification") :
            self.document.index("function Write-QualificationSuccess")
        ]
        live_resource_start = qualification.index(
            "Initialize-LiveQualificationResources"
        )
        provision_start = qualification.index(
            '"K_COMMS_LIVE_PROVISION_BASE_URL"',
            live_resource_start,
        )
        provision_setting = qualification[
            provision_start :
            qualification.index(
                '"K_COMMS_LIVE_OWNER_TENANT_SLUG"',
                provision_start,
            )
        ]
        self.assertIn("$script:LiveQualificationAppOrigin", provision_setting)
        self.assertNotIn("$script:LiveProvisionBaseUri", provision_setting)

    def test_trusted_edge_qualifies_public_object_transfer_and_cleanup(
        self,
    ) -> None:
        for proof in (
            "function Invoke-PublicObjectStorageQualification",
            "function Resolve-PublicObjectRequestDescriptor",
            "function Invoke-PublicObjectHttpRequest",
            "function Invoke-QualificationObjectPurge",
            "function Assert-QualificationObjectPurgeEvidence",
            "function Assert-PublicObjectStorageQualificationSelfTest",
            "function Assert-PublicObjectStorageTransportSelfTest",
            "Assert-PublicObjectStorageQualificationSelfTest",
            "Assert-PublicObjectStorageTransportSelfTest",
            "Get-QualificationBytesSha256",
            "Get-QualificationBytesSha256Base64",
            '"x-amz-checksum-sha256"',
            '"x-amz-meta-sha256"',
            "AllowAutoRedirect = $false",
            "Timeout = [TimeSpan]::FromSeconds(30)",
            "Public attachment scan did not become clean within 60 seconds",
            "Public attachment browser CORS preflight failed",
            "Access-Control-Request-Method",
            "Access-Control-Request-Headers",
            "AccessControlAllowOrigin",
            "K_COMMS_PUBLIC_OBJECT_PURGE_V1 verified_empty=true",
            "Public object remained downloadable after its ",
            "verified purge",
            "PASS disposable public attachment and object cleanup",
            "${function:Invoke-QualificationApiRequest}",
            "${function:Invoke-PublicObjectHttpRequest}",
            "${function:Invoke-QualificationObjectPurge}",
            "Self-test accepted cleanup without the exact purge marker",
            "Self-test did not prove the exact PUT/GET byte-hash roundtrip",
            "Self-test did not reject OPTIONS CORS failure before PUT",
            "Self-test did not aggregate the primary failure with all ",
            "$aggregateFailure.InnerExceptions.Count -eq 4",
        ):
            self.assertIn(proof, self.document)

        qualification = self.document[
            self.document.index("function Invoke-PackagedReleaseQualification") :
            self.document.index("function Write-QualificationSuccess")
        ]
        instant_room = qualification.index(
            "Invoke-InstantRoomSpec -Playwright $playwright"
        )
        public_object = qualification.index(
            "Invoke-PublicObjectStorageQualification",
            instant_room,
        )
        guest = qualification.index(
            "Invoke-GuestSpec -Playwright $playwright",
            public_object,
        )
        self.assertEqual(
            tuple(sorted((instant_room, public_object, guest))),
            (instant_room, public_object, guest),
        )
        object_gate = self.document[
            self.document.index("function Invoke-PublicObjectStorageQualification") :
            self.document.index("function Invoke-InstantRoomEndpointCheck")
        ]
        self.assertIn(
            "if (-not $script:QualificationMode.TrustedEdge)",
            object_gate,
        )
        abandon = object_gate.index(
            '-Method "DELETE" `\n'
            '                    -ExpectedStatus 204 `\n'
            '                    -Context "Disposable attachment abandonment"'
        )
        purge = object_gate.index(
            "& $PurgeAction",
            abandon,
        )
        public_absence = object_gate.index(
            "$deletedResponse = & $ObjectRequestAction",
            purge,
        )
        session_cleanup = object_gate.index(
            '-Path "/api/v1/sessions/current"',
            public_absence,
        )
        self.assertEqual(
            tuple(sorted((abandon, purge, public_absence, session_cleanup))),
            (abandon, purge, public_absence, session_cleanup),
        )
        for forbidden_output in (
            "Write-Host $accessToken",
            "Write-Output $accessToken",
            "Write-Host $uploadRequest",
            "Write-Output $uploadRequest",
            "Write-Host $downloadRequest",
            "Write-Output $downloadRequest",
            "$($result.Output -join",
        ):
            self.assertNotIn(forbidden_output, object_gate)

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

    def test_runs_instant_room_and_gates_credential_media_specs_by_mode(
        self,
    ) -> None:
        self.assertEqual(
            self.document.count('"e2e/live-instant-room.spec.ts"'),
            1,
        )
        self.assertEqual(
            self.document.count('"e2e/live-guest-communication.spec.ts"'),
            1,
        )
        self.assertEqual(self.document.count('"e2e/live-audio.spec.ts"'), 1)
        self.assertEqual(self.document.count('"e2e/live-video.spec.ts"'), 1)
        self.assertEqual(self.document.count('"--workers=1"'), 3)
        self.assertIn('"K_COMMS_EXTERNAL_E2E_SERVER"', self.document)
        self.assertIn('"K_COMMS_LIVE_INSTANT_ROOM_E2E"', self.document)
        self.assertIn('"K_COMMS_LIVE_GUEST_E2E"', self.document)
        self.assertIn('"K_COMMS_LIVE_AUDIO_E2E"', self.document)
        self.assertIn('"K_COMMS_LIVE_VIDEO_E2E"', self.document)
        self.assertIn("[switch]$LanTextOnly", self.document)
        self.assertIn(
            "if ($script:QualificationMode.LanTextOnly)",
            self.document,
        )
        self.assertIn(
            "Credential and media ",
            self.document,
        )
        self.assertIn(
            "credential and media operations were NOT qualified",
            self.document,
        )
        self.assertIn(
            "Anonymous create/join/roster/text passed",
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
        for variable, value in (
            (
                "K_COMMS_LIVE_INSTANT_ROOM_QUALIFICATION_APP_ORIGIN",
                r"\$script:LiveQualificationAppOrigin",
            ),
            (
                "K_COMMS_LIVE_INSTANT_ROOM_PUBLIC_ORIGIN",
                r"\$script:BaseUri",
            ),
            (
                "K_COMMS_LIVE_INSTANT_ROOM_TENANT_SLUG",
                r"\$script:LiveOwnerTenantSlug",
            ),
            (
                "K_COMMS_LIVE_INSTANT_ROOM_CLIENT_ADDRESS",
                r"\$script:LiveQualificationClientAddress",
            ),
        ):
            self.assertRegex(
                self.document,
                rf'"{variable}",\s+{value},\s+"Process"',
            )
        self.assertNotIn("K_COMMS_LIVE_INSTANT_ROOM_BASE_URL", self.document)
        qualification = self.document[
            self.document.index("function Invoke-PackagedReleaseQualification") :
            self.document.index("function Invoke-SelfTest")
        ]
        self.assertIn(
            "Invoke-InstantRoomSpec -Playwright $playwright",
            qualification,
        )
        self.assertIn("Invoke-GuestSpec -Playwright $playwright", qualification)
        self.assertLess(
            qualification.index("Invoke-InstantRoomSpec -Playwright $playwright"),
            qualification.index("Invoke-GuestSpec -Playwright $playwright"),
        )
        self.assertLess(
            qualification.index("Invoke-GuestSpec -Playwright $playwright"),
            qualification.index(
                'Invoke-MediaSpec -Kind "audio" -Playwright $playwright'
            ),
        )
        self.assertRegex(
            qualification,
            r"\[Environment\]::SetEnvironmentVariable\(\s*"
            r"\$name,\s*\$null,\s*\"Process\"\s*\)",
        )
        self.assertIn("Invoke-LanSecureTransportBoundaryCheck", qualification)
        self.assertIn("secure_transport_required", self.document)
        for forbidden_spec in (
            "e2e/accessibility.spec.ts",
            "e2e/mobile-ui.spec.ts",
            "e2e/member-ia.spec.ts",
            "e2e/smoke.spec.ts",
        ):
            self.assertNotIn(forbidden_spec, self.document)

    def test_live_instant_room_uses_isolated_creation_and_public_handoff(
        self,
    ) -> None:
        specification = LIVE_INSTANT_ROOM_SPEC.read_text(encoding="utf-8")
        for forbidden in (
            "K_COMMS_LIVE_INSTANT_ROOM_TEXT_ONLY",
            "K_COMMS_LIVE_INSTANT_ROOM_BASE_URL",
            "/api/v1/guest/account",
            "Save this room",
            "Create account",
            "conversionEmail",
            "storedMemberContinuity",
            "k-comms.member-instant-room.v1",
            'accountType: "human"',
            ".route(",
        ):
            self.assertNotIn(forbidden, specification)
        for anonymous_proof in (
            "creates in isolation then communicates through the retained public app",
            'accountType: "guest",',
            "qualificationRoomContext(",
            'extraHTTPHeaders: { "X-Forwarded-For": clientAddress }',
            "createRequestUsedQualificationOriginHeader",
            'request.headerValue("x-forwarded-for")',
            'request.headerValue("origin")',
            "captureGuestSessionForHandoff(qualificationPage)",
            "installGuestSessionHandoff(",
            "assertInstantRoomShareURL(shareURL, publicOrigin)",
            "url.origin === publicOrigin",
            "expect(publicRequestUsedForwardedFor).toBe(false)",
            "guestPage.getByRole(\"textbox\", {",
            ").toHaveCount(0)",
            "2 people online",
            "Host live reply",
            "Guest live message",
            "url.pathname === \"/api/v1/guest/sessions/current\"",
            "expect(response.status()).toBe(204)",
            "expect(await storedGuestRoomIdentity(hostPage)).toEqual(hostIdentity)",
            "expect(await storedGuestRoomIdentity(guestPage)).toEqual(guestIdentity)",
            'test.use({ trace: "off", screenshot: "off", video: "off" })',
            'input.value = "[redacted secure room link]"',
        ):
            self.assertIn(anonymous_proof, specification)
        self.assertNotIn("request.headers().origin", specification)
        for required_environment in (
            "K_COMMS_LIVE_INSTANT_ROOM_QUALIFICATION_APP_ORIGIN",
            "K_COMMS_LIVE_INSTANT_ROOM_PUBLIC_ORIGIN",
            "K_COMMS_LIVE_INSTANT_ROOM_TENANT_SLUG",
            "K_COMMS_LIVE_INSTANT_ROOM_CLIENT_ADDRESS",
        ):
            self.assertIn(required_environment, specification)
        self.assertNotIn("K_COMMS_LIVE_INSTANT_ROOM_TEXT_ONLY", self.document)

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

    def test_conversion_is_bound_to_the_marker_cleaned_disposable_tenant(
        self,
    ) -> None:
        specification = LIVE_GUEST_SPEC.read_text(encoding="utf-8")
        for disposable_tenant_proof in (
            "a guest in the disposable qualification tenant converts in place",
            "/^k-comms-qualification-[0-9a-f]{32}$/",
            "sealed guest qualification requires a disposable marker-bound tenant",
            "id: ownerFixture.owner.tenant.id",
            "slug: ownerFixture.owner.tenant.slug",
        ):
            self.assertIn(disposable_tenant_proof, specification)

        qualification = self.document[
            self.document.index("function Invoke-PackagedReleaseQualification") :
            self.document.index("function Invoke-SelfTest")
        ]
        initialize = qualification.index("Initialize-LiveQualificationResources")
        guest = qualification.index("Invoke-GuestSpec -Playwright $playwright")
        final_recovery = qualification.index(
            "Recover-StaleLiveQualificationResources",
            guest,
        )
        fingerprint_after = qualification.index(
            "$fixedTenantFingerprintAfter",
            final_recovery,
        )
        self.assertEqual(
            tuple(sorted((initialize, guest, final_recovery, fingerprint_after))),
            (initialize, guest, final_recovery, fingerprint_after),
        )
        cleanup = qualification[final_recovery:]
        self.assertIn(
            "-CleanupReceiptPath `\n"
            "                        $script:QualificationCleanupReceiptPath",
            cleanup,
        )

    def test_live_specs_use_the_sealed_owner_without_public_bootstrap(self) -> None:
        for path in (LIVE_GUEST_SPEC, LIVE_AUDIO_SPEC, LIVE_VIDEO_SPEC):
            with self.subTest(path=path.name):
                specification = path.read_text(encoding="utf-8")
                self.assertNotIn("/api/v1/bootstrap", specification)
                self.assertIn("K_COMMS_LIVE_PROVISION_BASE_URL", specification)
                self.assertIn("K_COMMS_LIVE_OWNER_TENANT_SLUG", specification)
                self.assertIn("K_COMMS_LIVE_OWNER_EMAIL", specification)
                self.assertIn("K_COMMS_LIVE_OWNER_PASSWORD", specification)
                self.assertIn("/api/v1/sessions", specification)
                self.assertIn("/api/v1/sessions/current", specification)

        for name in (
            "K_COMMS_QUALIFICATION_ACTION",
            "K_COMMS_QUALIFICATION_ID",
            "K_COMMS_QUALIFICATION_PASSWORD",
            "K_COMMS_QUALIFICATION_CONFIRMATION",
            "K_COMMS_LIVE_PROVISION_BASE_URL",
            "K_COMMS_LIVE_OWNER_TENANT_SLUG",
            "K_COMMS_LIVE_OWNER_EMAIL",
            "K_COMMS_LIVE_OWNER_PASSWORD",
        ):
            self.assertIn(name, self.document)
        self.assertIn(
            '$script:LiveProvisionBaseUri = "http://127.0.0.1:$($target.AppPort)"',
            self.document,
        )
        self.assertNotIn("Get-SealedEnvironmentValue", self.document)
        self.assertIn("Initialize-LiveQualificationResources", self.document)
        self.assertIn(
            '-Action "create" `',
            self.document,
        )
        self.assertIn(
            '-Action "delete" `',
            self.document,
        )
        self.assertIn(
            '"k-comms-qualification-$($script:LiveQualificationId)"',
            self.document,
        )
        self.assertIn(
            "local-release-qualification-tenant-v1",
            self.document,
        )
        self.assertIn("qualification-cleanup.json", self.document)
        self.assertIn("Recover-StaleLiveQualificationResources", self.document)
        self.assertIn("Write-QualificationCleanupReceipt", self.document)
        self.assertIn("Remove-LiveQualificationResources", self.document)

    def test_qualification_uses_the_manager_operation_lock_and_revalidates(self) -> None:
        self.assertIn(
            '"Local\\KComms.LocalRelease.$ComposeProject"',
            self.document,
        )
        self.assertIn('[IO.FileShare]::None', self.document)
        self.assertIn("Assert-QualificationLockAndStateSelfTest", self.document)

        serialized = self.document[
            self.document.index(
                "function Invoke-SerializedPackagedReleaseQualification"
            ) :
            self.document.index(
                "function Assert-QualificationLockAndStateSelfTest"
            )
        ]
        discover = serialized.index("Assert-SealedReleaseIsRunning")
        acquire = serialized.index("Enter-QualificationOperationLock")
        locked_revalidation = serialized.index(
            "Assert-SealedReleaseIsRunning",
            acquire,
        )
        browser_work = serialized.index(
            "Invoke-PackagedReleaseQualification",
            locked_revalidation,
        )
        final_revalidation = serialized.index(
            "Assert-SealedReleaseIsRunning",
            browser_work,
        )
        success = serialized.index(
            "Write-QualificationSuccess",
            final_revalidation,
        )
        release = serialized.index(
            "Exit-QualificationOperationLock",
            success,
        )
        ordered_steps = (
            discover,
            acquire,
            locked_revalidation,
            browser_work,
            final_revalidation,
            success,
            release,
        )
        self.assertEqual(tuple(sorted(ordered_steps)), ordered_steps)

    def test_cleanup_receipt_is_release_state_global_across_candidate_switches(
        self,
    ) -> None:
        self.assertIn(
            "Resolve-QualificationStateRoot -ReceiptPath $receiptPath",
            self.document,
        )
        self.assertIn(
            "Join-Path `\n            $script:QualificationStateRoot `\n"
            '            "qualification-cleanup.json"',
            self.document,
        )
        self.assertIn(
            "Self-test did not retain cleanup recovery across a receipt switch",
            self.document,
        )
        self.assertIn(
            "The retained qualification cleanup receipt belongs to another ",
            self.document,
        )
        self.assertNotIn(
            "(Split-Path -Parent $environmentFile) `\n"
            '                "qualification-cleanup.json"',
            self.document,
        )

    def test_cleanup_marker_is_secret_free_and_binds_origin_assets(self) -> None:
        for binding in (
            "schemaVersion = 3",
            'kind = "k-comms-qualification-cleanup"',
            "tenantSlug = $tenantSlug",
            "qualificationAppContainerName = $AppContainerName",
            "qualificationAppNonce = $AppNonce",
            "qualificationAppHostPort = $AppHostPort",
            "qualificationAppOrigin = $AppOrigin",
            "qualificationAppTrustedProxyCidr = $AppTrustedProxyCidr",
            "qualificationClientAddress = $ClientAddress",
            "publicAppUrl = $PublicAppUrl",
            "receiptPath = $ReleaseContext.ReceiptPath",
            "receiptSha256 = $ReleaseContext.ReceiptSha256",
            "environmentFile = $ReleaseContext.EnvironmentFile",
            "environmentSha256 = $ReleaseContext.EnvironmentSha256",
            "composeSourcePath = $ReleaseContext.ComposeSourcePath",
            "composeSourceSha256 = $ReleaseContext.ComposeSourceSha256",
            "imageReference = $ReleaseContext.ImageReference",
            "imageId = $ReleaseContext.ImageId",
            "revision = $ReleaseContext.Revision",
        ):
            self.assertIn(binding, self.document)
        marker_writer = self.document[
            self.document.index("function Write-QualificationCleanupReceipt") :
            self.document.index("function Remove-LiveQualificationResources")
        ]
        for forbidden in (
            "LiveOwnerPassword",
            "K_COMMS_QUALIFICATION_PASSWORD",
            "DATABASE_URL",
            "SECRET_KEY_BASE",
        ):
            self.assertNotIn(forbidden, marker_writer)

    def test_isolated_app_lifecycle_and_fixed_tenant_guard_are_ordered(self) -> None:
        start = self.document[
            self.document.index("function Start-LiveQualificationApp") :
            self.document.index("function Remove-LiveQualificationApp")
        ]
        for proof in (
            '"run", "--detach", "--no-deps", "--pull", "never"',
            '"127.0.0.1:$($CleanupContext.AppHostPort):4000"',
            '"--env", "K_COMMS_ROLE=edge"',
            '"--env", "ALLOW_BOOTSTRAP=false"',
            '"INSTANT_ROOM_TENANT_SLUG="',
            '"PUBLIC_APP_URL=$qualificationPublicAppUrl"',
            '"--env", "K_COMMS_RELEASE_EXPOSURE_MODE="',
            '"--env", "K_COMMS_TRUSTED_EDGE_CONFIRMATION="',
            '"CORS_ORIGINS=$($CleanupContext.AppOrigin)"',
            '"K_COMMS_QUALIFICATION_SHARE_ORIGIN="',
            "$CleanupContext.PublicAppUrl",
            '"com.k-comms.qualification.nonce="',
            '"com.k-comms.qualification.revision="',
            "Invoke-QualificationNativeCommand `",
            "app",
            "Assert-LiveQualificationAppRuntime",
        ):
            self.assertIn(proof, start)
        self.assertNotIn("run --rm", start)

        removal = self.document[
            self.document.index("function Remove-LiveQualificationApp") :
            self.document.index("function Write-QualificationCleanupReceipt")
        ]
        self.assertLess(
            removal.index("Assert-QualificationAppContainerIdentity"),
            removal.index("$removeResult = Invoke-QualificationNativeCommand"),
        )
        self.assertLess(
            removal.index("$removeResult = Invoke-QualificationNativeCommand"),
            removal.index("PASS isolated qualification app removal"),
        )

        cleanup = self.document[
            self.document.index("function Remove-LiveQualificationResources") :
            self.document.index("function Resolve-QualificationCleanupReceipt")
        ]
        app = cleanup.index("Remove-LiveQualificationApp")
        tenant = cleanup.index("Invoke-QualificationTenantOperation")
        marker = cleanup.index(
            "Remove-Item -LiteralPath $CleanupReceiptPath -Force"
        )
        self.assertEqual(tuple(sorted((app, tenant, marker))), (app, tenant, marker))

        qualification = self.document[
            self.document.index("function Invoke-PackagedReleaseQualification") :
            self.document.index("function Write-QualificationSuccess")
        ]
        initial_recovery = qualification.index(
            "Recover-StaleLiveQualificationResources"
        )
        fingerprint_before = qualification.index(
            "$fixedTenantFingerprintBefore =",
            initial_recovery,
        )
        initialize = qualification.index(
            "Initialize-LiveQualificationResources",
            fingerprint_before,
        )
        browser = qualification.index(
            "Invoke-InstantRoomSpec -Playwright $playwright",
            initialize,
        )
        final_recovery = qualification.index(
            "Recover-StaleLiveQualificationResources",
            browser,
        )
        fingerprint_after = qualification.index(
            "$fixedTenantFingerprintAfter =",
            final_recovery,
        )
        self.assertEqual(
            tuple(
                sorted(
                    (
                        initial_recovery,
                        fingerprint_before,
                        initialize,
                        browser,
                        final_recovery,
                        fingerprint_after,
                    )
                )
            ),
            (
                initial_recovery,
                fingerprint_before,
                initialize,
                browser,
                final_recovery,
                fingerprint_after,
            ),
        )
        for failure_guard in (
            "$primaryFailure = $_.Exception",
            "$cleanupFailure = [InvalidOperationException]::new(",
            "$fingerprintFailure = [InvalidOperationException]::new(",
            "throw [AggregateException]::new(",
        ):
            self.assertIn(failure_guard, qualification)

        for fingerprint_guard in (
            "function Get-FixedInstantRoomTenantFingerprint",
            "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION",
            "fixed-instant-room-tenant-fingerprint-v1",
            "instant_room_tenant_fingerprint()",
        ):
            self.assertIn(fingerprint_guard, self.document)

    def test_stale_cleanup_validates_and_uses_origin_release_context(self) -> None:
        for proof in (
            "Resolve-CanonicalQualificationPath",
            "Assert-QualificationPathsAreNotReparsePoints",
            "Get-QualificationFileSha256",
            "the exact schema-v$schemaVersion properties",
            "its originating release",
            "Assert-QualificationReleaseImageIdentity -ReleaseContext",
            '"--env-file", [string]$ReleaseContext.EnvironmentFile',
            '"--file", [string]$ReleaseContext.ComposeSourcePath',
            '"--project-name", [string]$ReleaseContext.ProjectName',
            "Self-test accepted a cleanup marker switched to the current",
            "Self-test accepted a tampered originating release",
            "Self-test accepted an extra cleanup marker property",
            "Self-test allowed a same-name decoy qualification app",
            "Self-test crash recovery did not remove app, then tenant",
            "Self-test did not preserve schema-v2 tenant-only recovery",
            "-WithoutQualificationService",
        ):
            self.assertIn(proof, self.document)
        recovery = self.document[
            self.document.index("function Recover-StaleLiveQualificationResources") :
            self.document.index("function Initialize-LiveQualificationResources")
        ]
        self.assertLess(
            recovery.index("Resolve-QualificationCleanupReceipt"),
            recovery.index("Remove-LiveQualificationResources"),
        )
        self.assertNotIn("$script:SealedReleaseEnvironmentFile", recovery)
        self.assertNotIn("$script:SealedReleaseComposeSourcePath", recovery)


if __name__ == "__main__":
    unittest.main()
