#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml
from validate_local_release import (
    DEFAULT_COMPOSE,
    DEFAULT_RUNNER,
    ROOT,
    _function_body,
    validate_local_release,
    validate_paths,
)

WINDOWS_POWERSHELL = shutil.which("powershell.exe")


class LocalReleasePolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.compose = yaml.safe_load(DEFAULT_COMPOSE.read_text(encoding="utf-8"))
        self.runner = DEFAULT_RUNNER.read_text(encoding="utf-8")

    def test_repository_assets_pass(self) -> None:
        self.assertEqual(validate_paths(DEFAULT_COMPOSE, DEFAULT_RUNNER), [])

    def test_build_context_excludes_ignored_vite_environment_files(self) -> None:
        patterns = {
            line.strip()
            for line in (ROOT / ".dockerignore").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertTrue(
            {"**/.env", "**/.env.*"}.issubset(patterns),
            "ignored nested .env files must not influence an exact-revision image",
        )

    def test_rejects_source_mounts_or_vite_service(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["app"]["volumes"] = ["..:/workspace"]
        document["services"]["web"] = {
            "image": "node:latest",
            "command": "npm run dev",
        }
        errors = validate_local_release(document, self.runner)
        self.assertTrue(any("must be exactly" in error for error in errors))
        self.assertIn(
            "local release must serve packaged assets from Phoenix, not Vite", errors
        )
        self.assertIn("service 'app' must not use source or host bind mounts", errors)

    def test_rejects_mutable_dependency_images_and_broad_ports(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["postgres"]["image"] = "postgres:17"
        document["services"]["app"]["ports"] = ["0.0.0.0:4188:4000"]
        errors = validate_local_release(document, self.runner)
        self.assertIn(
            "service 'postgres' image must be pinned by sha256 digest", errors
        )
        self.assertTrue(any("service 'app' ports must be" in error for error in errors))
        self.assertTrue(
            any(
                "wildcard and direct RFC1918 binds are forbidden" in error
                for error in errors
            )
        )

    def test_rejects_incomplete_local_release_gates(self) -> None:
        document = copy.deepcopy(self.compose)
        del document["services"]["app"]["environment"]["ALLOW_DEVELOPMENT_ADAPTERS"]
        document["services"]["app"]["environment"]["LIVEKIT_API_URL"] = (
            "http://other-media:7880"
        )
        errors = validate_local_release(document, self.runner)
        self.assertTrue(any("development-adapter gate" in error for error in errors))
        self.assertIn(
            "service 'app' must use only the internal livekit:7880 API origin", errors
        )

    def test_requires_bounded_instant_room_environment(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["app"]["environment"].pop(
            "INSTANT_ROOM_PRESENCE_LEASE_SECONDS"
        )
        errors = validate_local_release(document, self.runner)
        self.assertIn(
            "service 'app' must set INSTANT_ROOM_PRESENCE_LEASE_SECONDS="
            "${INSTANT_ROOM_PRESENCE_LEASE_SECONDS:-90} for bounded "
            "instant-room qualification",
            errors,
        )

    def test_requires_bounded_isolated_qualification_tenant_service(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["qualification"]["command"] = [
            "eval",
            "CommsCore.Release.bootstrap()",
        ]
        document["services"]["qualification"]["environment"][
            "K_COMMS_RUNTIME_PURPOSE"
        ] = "application"
        document["services"]["qualification"]["environment"].pop(
            "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION"
        )
        document["services"]["qualification"]["ports"] = ["127.0.0.1:4999:4000"]

        errors = validate_local_release(document, self.runner)

        self.assertIn(
            "qualification service must run only "
            "CommsCore.Release.qualification_tenant()",
            errors,
        )
        self.assertTrue(
            any(
                "qualification service must set K_COMMS_RUNTIME_PURPOSE=one_shot"
                in error
                for error in errors
            )
        )
        self.assertTrue(
            any(
                "qualification service must set "
                "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION="
                "${K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION:-}"
                in error
                for error in errors
            )
        )
        self.assertIn(
            "service 'qualification' must not publish a host port",
            errors,
        )

    def test_requires_sealed_instant_room_provisioning_and_candidate_capability(
        self,
    ) -> None:
        missing_capability = self.runner.replace(
            '$instantRooms = $capabilities.PSObject.Properties["instant_rooms"]',
            '$instantRooms = $capabilities.PSObject.Properties["removed"]',
        )
        errors = validate_local_release(self.compose, missing_capability)
        self.assertIn(
            "candidate health checks must support explicit instant-rooms "
            "capability enforcement",
            errors,
        )

        missing_bootstrap = self.runner.replace(
            "    Ensure-InstantRoomTenant `",
            "    Write-Warning 'instant-room bootstrap removed' `",
        )
        errors = validate_local_release(self.compose, missing_bootstrap)
        self.assertIn(
            "local release must provision and verify the fixed instant-room tenant "
            "through the sealed one-shot release command before candidate or "
            "restored-release capability checks",
            errors,
        )

        public_bootstrap = copy.deepcopy(self.compose)
        public_bootstrap["services"]["app"]["environment"]["ALLOW_BOOTSTRAP"] = (
            "${ALLOW_BOOTSTRAP:-true}"
        )
        public_bootstrap["services"]["bootstrap"]["environment"][
            "ALLOW_BOOTSTRAP"
        ] = "true"
        public_bootstrap["services"]["bootstrap"]["command"] = [
            "eval",
            "CommsCore.Release.migrate()",
        ]
        errors = validate_local_release(public_bootstrap, self.runner)
        self.assertIn(
            "service 'app' must default the public bootstrap endpoint to disabled",
            errors,
        )
        self.assertIn(
            "bootstrap service must run only CommsCore.Release.bootstrap()",
            errors,
        )
        self.assertTrue(
            any(
                "bootstrap service must set ALLOW_BOOTSTRAP=false" in error
                for error in errors
            )
        )

        missing_runtime_seal = self.runner.replace(
            "        Start-SealedApplication `",
            "        Invoke-Compose `",
        )
        self.assertIn(
            "candidate deployment must activate the application through the "
            "sealed public-bootstrap helper",
            validate_local_release(self.compose, missing_runtime_seal),
        )

        public_bootstrap_health = self.runner.replace(
            '$bootstrap = $capabilities.PSObject.Properties["bootstrap"]',
            '$bootstrap = $capabilities.PSObject.Properties["removed"]',
        )
        self.assertIn(
            "release health and self-tests must require the public bootstrap "
            "endpoint to remain disabled",
            validate_local_release(self.compose, public_bootstrap_health),
        )

    def test_requires_valid_repairable_stable_encryption_keys(self) -> None:
        invalid_generator = self.runner.replace(
            "WEBHOOK_SECRET_ENCRYPTION_KEY = New-EncryptionKey",
            "WEBHOOK_SECRET_ENCRYPTION_KEY = New-UrlSafeSecret 48",
        )
        errors = validate_local_release(self.compose, invalid_generator)
        self.assertIn(
            "local release must generate valid AES-256 keys, repair only the "
            "known never-valid legacy format, reject unknown retained corruption, "
            "and exercise that policy during validation",
            errors,
        )

        missing_self_test = self.runner.replace(
            "        Invoke-StableEncryptionKeySelfTest",
            '        Write-Host "stable encryption-key self-test removed"',
        )
        errors = validate_local_release(self.compose, missing_self_test)
        self.assertIn(
            "local release must generate valid AES-256 keys, repair only the "
            "known never-valid legacy format, reject unknown retained corruption, "
            "and exercise that policy during validation",
            errors,
        )

    def test_rejects_incomplete_livekit_media_port_configuration(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["livekit"]["command"] = [
            "--node-ip",
            "127.0.0.1",
            "--udp-port",
            "7882",
        ]
        errors = validate_local_release(document, self.runner)
        self.assertTrue(any("local media setting" in error for error in errors))

    def test_requires_explicit_private_lan_topology_contract(self) -> None:
        document = copy.deepcopy(self.compose)
        del document["services"]["app"]["environment"][
            "K_COMMS_LOCAL_RELEASE_HOST"
        ]
        del document["services"]["app"]["environment"][
            "K_COMMS_PODMAN_BIND_ADDRESS"
        ]
        document["services"]["app"]["environment"][
            "K_COMMS_RELEASE_BIND_ADDRESS"
        ] = "${K_COMMS_RELEASE_BIND_ADDRESS:-127.0.0.1}"
        document["services"]["minio"]["ports"][1] = (
            "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}:"
            "${K_COMMS_RELEASE_MINIO_CONSOLE_PORT:-5901}:9001"
        )
        errors = validate_local_release(document, self.runner)
        self.assertTrue(
            any(
                "K_COMMS_LOCAL_RELEASE_HOST=${K_COMMS_LOCAL_RELEASE_HOST:-}"
                in error
                for error in errors
            )
        )
        self.assertTrue(
            any(
                "K_COMMS_PODMAN_BIND_ADDRESS="
                "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}" in error
                for error in errors
            )
        )
        self.assertIn(
            "service 'app' must not receive the legacy direct-bind variable "
            "K_COMMS_RELEASE_BIND_ADDRESS",
            errors,
        )
        self.assertTrue(
            any("service 'minio' ports must be" in error for error in errors)
        )

    def test_rejects_wildcard_or_direct_lan_podman_bindings(self) -> None:
        for unsafe_mapping in (
            "0.0.0.0:${K_COMMS_RELEASE_APP_PORT:-4188}:4000",
            "192.168.50.12:${K_COMMS_RELEASE_APP_PORT:-4188}:4000",
            (
                "${K_COMMS_RELEASE_BIND_ADDRESS:-127.0.0.1}:"
                "${K_COMMS_RELEASE_APP_PORT:-4188}:4000"
            ),
        ):
            with self.subTest(unsafe_mapping=unsafe_mapping):
                document = copy.deepcopy(self.compose)
                document["services"]["app"]["ports"] = [unsafe_mapping]
                errors = validate_local_release(document, self.runner)
                self.assertTrue(
                    any(
                        "wildcard and direct RFC1918 binds are forbidden" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_requires_compose_ambient_environment_sealing_and_restoration(
        self,
    ) -> None:
        expected = (
            "every Compose call must seal all retained and referenced "
            "interpolation variables against ambient process overrides, force "
            "the Podman bind to loopback, and restore the caller environment"
        )
        mutations = (
            (
                (
                    "    Invoke-WithSealedComposeEnvironment `\n"
                    "        -EnvironmentFile $EnvironmentFile `"
                ),
                (
                    "    Removed-SealedComposeEnvironment `\n"
                    "        -EnvironmentFile $EnvironmentFile `"
                ),
            ),
            (
                (
                    '            "K_COMMS_PODMAN_BIND_ADDRESS",\n'
                    "            $podmanBindAddress,"
                ),
                (
                    '            "K_COMMS_PODMAN_BIND_ADDRESS",\n'
                    '            "0.0.0.0",'
                ),
            ),
            (
                (
                    "    finally {\n"
                    "        foreach ($name in $names) {"
                ),
                (
                    "    if ($false) {\n"
                    "        foreach ($name in $names) {"
                ),
            ),
            (
                "            Exists = $processEnvironmentNames.ContainsKey($name)",
                "            Exists = $processEnvironment.Contains($name)",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                runner = self.runner.replace(original, replacement)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    @unittest.skipUnless(
        WINDOWS_POWERSHELL,
        "Windows PowerShell is required for this runtime self-test",
    )
    def test_compose_environment_seal_blocks_ambient_overrides_at_runtime(
        self,
    ) -> None:
        function_sources = "\n".join(
            f"function {name} {{"
            f"{_function_body(self.runner, name)}"
            for name in (
                "Read-EnvironmentFile",
                "Get-ComposeInterpolationNames",
                "Invoke-WithSealedComposeEnvironment",
            )
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = ROOT / Path(temporary_directory)
            environment_path = temporary_path / "release.env"
            compose_path = temporary_path / "compose.yaml"
            test_script_path = temporary_path / "sealed-compose-self-test.ps1"
            environment_path.write_text(
                "K_COMMS_PODMAN_BIND_ADDRESS=127.0.0.1\n"
                "K_COMMS_RELEASE_HOST=192.168.50.12\n"
                "RETAINED_ONLY=sealed-value\n",
                encoding="utf-8",
            )
            compose_path.write_text(
                "services:\n"
                "  app:\n"
                "    image: example.invalid/app:sealed\n"
                "    environment:\n"
                "      HOST: ${K_COMMS_RELEASE_HOST}\n"
                "      ABSENT: ${REFERENCED_BUT_ABSENT:-default}\n"
                "    ports:\n"
                '      - "${K_COMMS_PODMAN_BIND_ADDRESS}:4188:4000"\n',
                encoding="utf-8",
            )
            quoted_environment_path = str(environment_path).replace("'", "''")
            quoted_compose_path = str(compose_path).replace("'", "''")
            driver = f"""
$ErrorActionPreference = "Stop"
$podmanBindAddress = "127.0.0.1"
$environmentPath = '{quoted_environment_path}'
$composePath = '{quoted_compose_path}'
$ambient = [ordered]@{{
    K_COMMS_PODMAN_BIND_ADDRESS = "0.0.0.0"
    K_COMMS_RELEASE_HOST = "203.0.113.10"
    RETAINED_ONLY = "ambient-retained-value"
    referenced_but_absent = "ambient-absent-value"
}}
foreach ($entry in $ambient.GetEnumerator()) {{
    [Environment]::SetEnvironmentVariable(
        $entry.Key,
        $entry.Value,
        [EnvironmentVariableTarget]::Process
    )
}}
$script:actionObservedSealedValues = $false
Invoke-WithSealedComposeEnvironment `
    -EnvironmentFile $environmentPath `
    -ComposePath $composePath `
    -Action {{
        if ($env:K_COMMS_PODMAN_BIND_ADDRESS -cne "127.0.0.1") {{
            throw "ambient wildcard reached Compose"
        }}
        if ($env:K_COMMS_RELEASE_HOST -cne "192.168.50.12") {{
            throw "ambient public host reached Compose"
        }}
        if ($env:RETAINED_ONLY -cne "sealed-value") {{
            throw "ambient retained-only value reached Compose"
        }}
        if ($null -ne [Environment]::GetEnvironmentVariable(
            "REFERENCED_BUT_ABSENT",
            [EnvironmentVariableTarget]::Process
        )) {{
            throw "ambient absent value reached Compose"
        }}
        $script:actionObservedSealedValues = $true
    }}
if (-not $script:actionObservedSealedValues) {{
    throw "sealed action was not executed"
}}
foreach ($entry in $ambient.GetEnumerator()) {{
    $restored = [Environment]::GetEnvironmentVariable(
        $entry.Key,
        [EnvironmentVariableTarget]::Process
    )
    if ($restored -cne $entry.Value) {{
        throw "ambient value was not restored after success: $($entry.Key)"
    }}
}}
$restoredNames = @(
    [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    ).Keys
)
if (-not @(
    $restoredNames |
        Where-Object {{ [string]$_ -ceq "referenced_but_absent" }}
).Count) {{
    throw "mixed-case ambient key spelling was not restored after success"
}}
$expectedFailureObserved = $false
try {{
    Invoke-WithSealedComposeEnvironment `
        -EnvironmentFile $environmentPath `
        -ComposePath $composePath `
        -Action {{ throw "expected sealed-action failure" }}
}}
catch {{
    if ($_.Exception.Message -cne "expected sealed-action failure") {{
        throw
    }}
    $expectedFailureObserved = $true
}}
if (-not $expectedFailureObserved) {{
    throw "failing sealed action did not fail"
}}
foreach ($entry in $ambient.GetEnumerator()) {{
    $restored = [Environment]::GetEnvironmentVariable(
        $entry.Key,
        [EnvironmentVariableTarget]::Process
    )
    if ($restored -cne $entry.Value) {{
        throw "ambient value was not restored after failure: $($entry.Key)"
    }}
}}
$restoredNames = @(
    [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    ).Keys
)
if (-not @(
    $restoredNames |
        Where-Object {{ [string]$_ -ceq "referenced_but_absent" }}
).Count) {{
    throw "mixed-case ambient key spelling was not restored after failure"
}}
Write-Output "sealed Compose environment runtime self-test passed"
"""
            test_script_path.write_text(
                function_sources + driver,
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    WINDOWS_POWERSHELL,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(test_script_path),
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
                "sealed Compose environment runtime self-test passed",
                result.stdout,
            )

    def test_rejects_unsafe_or_unassigned_bind_address_policy(self) -> None:
        runner = self.runner.replace(
            '$canonical -eq "0.0.0.0"',
            '$canonical -eq "removed-wildcard"',
        ).replace(
            "Test-IPv4AssignedLocally -Address $parsed",
            "RemovedLocalAddressCheck -Address $parsed",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "BindAddress must be canonical IPv4, never wildcard, loopback or "
            "RFC1918 only, and an RFC1918 address must be assigned to an active "
            "local interface",
            errors,
        )

    def test_requires_canonical_ipv4_and_profile_override_policy(self) -> None:
        runner = self.runner.replace(
            "$Value -cne $canonical",
            "$Value -ceq $canonical",
        ).replace(
            "if (-not $AllowPublicNetworkProfile)",
            "if ($false)",
            1,
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "BindAddress must be canonical IPv4, never wildcard, loopback or "
            "RFC1918 only, and an RFC1918 address must be assigned to an active "
            "local interface",
            errors,
        )
        self.assertIn(
            "LAN release selection must require one exact Preferred Windows IPv4 "
            "address, and non-Private network profiles must fail closed unless an "
            "explicit audited AllowPublicNetworkProfile override is supplied",
            errors,
        )

    def test_rejects_firewall_profile_or_portproxy_mutation(self) -> None:
        for forbidden_command in (
            "New-NetFirewallRule -DisplayName 'K-Comms'",
            "Set-NetFirewallRule -DisplayName 'K-Comms'",
            "Remove-NetFirewallRule -DisplayName 'K-Comms'",
            "Set-NetConnectionProfile -NetworkCategory Private",
            "netsh advfirewall firewall add rule name=K-Comms",
            "netsh interface portproxy add v4tov4",
        ):
            with self.subTest(forbidden_command=forbidden_command):
                errors = validate_local_release(
                    self.compose,
                    self.runner + f"\n{forbidden_command}\n",
                )
                self.assertIn(
                    "local release orchestration must never mutate Windows "
                    "Firewall, network profiles, or port-proxy state",
                    errors,
                )

    def test_rejects_non_preferred_windows_address_policy(self) -> None:
        runner = self.runner.replace(
            '$AddressRecord.AddressState -ceq "Preferred"',
            '$AddressRecord.AddressState -ne "Invalid"',
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "LAN release selection must require one exact Preferred Windows IPv4 "
            "address, and non-Private network profiles must fail closed unless an "
            "explicit audited AllowPublicNetworkProfile override is supplied",
            errors,
        )

    def test_requires_executable_interface_and_profile_drift_checks(self) -> None:
        runner = self.runner.replace(
            "Assert-ReleaseNetworkObservationMatches",
            "RemovedNetworkObservationMatch",
        ).replace(
            "Network-profile self-test accepted drift",
            "Network-profile self-test ignored drift",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "LAN deployment must revalidate the selected interface and network "
            "profile before activation and before sealing its receipt",
            errors,
        )

    def test_requires_profile_receipt_and_activation_revalidation(self) -> None:
        runner = self.runner.replace(
            "Assert-ReleaseNetworkObservationCurrent",
            "RemovedCurrentNetworkObservation",
        ).replace(
            "publicNetworkProfileOverrideUsed =",
            "removedProfileOverride =",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "LAN deployment must revalidate the selected interface and network "
            "profile before activation and before sealing its receipt",
            errors,
        )
        self.assertIn(
            "release receipts must persist the observed Windows interface and "
            "network profile plus the audited non-Private-profile override",
            errors,
        )

    def test_requires_address_aware_health_and_receipt_lifecycle(self) -> None:
        runner = self.runner.replace(
            "-ExpectedBindAddress $BindAddress `",
            "-RemovedBindAddress $BindAddress `",
        ).replace(
            "network = New-ReceiptNetworkRecord",
            "removedTopology = RemovedReceiptNetworkRecord",
        ).replace(
            "Resolve-ReceiptNetworkTopology -Receipt $current",
            "RemovedReceiptTopology -Receipt $current",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "deployment and restore must prove loopback Podman bootstrap and "
            "health before activating, identity-checking, and publicly probing "
            "a required LAN forwarder",
            errors,
        )
        self.assertIn(
            "release receipts must persist and revalidate the exact bind address, "
            "public host, and public application origin",
            errors,
        )
        self.assertIn(
            "Status must re-observe and expose an explicit receipt-network match, "
            "and Rollback must revalidate both retained network topologies",
            errors,
        )

    def test_requires_hash_bound_forwarder_receipt_and_configuration(
        self,
    ) -> None:
        expected = (
            "schema-v5 LAN receipts must seal an immutable, hash-bound "
            "forwarder configuration with exact loopback-targeted TCP/UDP "
            "listeners and bounded resource limits"
        )
        mutations = (
            (
                "scriptSha256 = $scriptSha256",
                "removedHash = $scriptSha256",
            ),
            (
                "targetHost = $podmanBindAddress",
                "targetHost = $ExpectedBindAddress",
            ),
            (
                "maxUdpMappings = 256",
                "removedLimit = 256",
            ),
            (
                (
                    "        required = $false\n"
                    '        kind = "not-required"'
                ),
                (
                    "        required = $true\n"
                    '        kind = "incorrect-loopback-forwarder"'
                ),
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                runner = self.runner.replace(original, replacement)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    def test_requires_receipt_bound_forwarder_readiness_evidence(self) -> None:
        expected = (
            "forwarder readiness must prove receipt-bound process identity, "
            "configuration hash, token, start time, and exact TCP/UDP listener "
            "ownership"
        )
        mutations = (
            (
                '"lan_release_forwarder_ready"',
                '"removed_forwarder_ready_event"',
            ),
            (
                '-Name "processStartTimeUtc"',
                '-Name "removedProcessStartTimeUtc"',
            ),
            (
                "Get-NetUDPEndpoint",
                "Removed-NetUDPEndpoint",
            ),
            (
                "Where-Object { [int]$_.OwningProcess -eq $pidValue }",
                "Where-Object { $false }",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                runner = self.runner.replace(original, replacement)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    def test_requires_datetime_ready_process_start_normalization(self) -> None:
        expected = (
            "forwarder readiness must prove receipt-bound process identity, "
            "configuration hash, token, start time, and exact TCP/UDP listener "
            "ownership"
        )
        mutations = (
            (
                "if ($readyProcessStartValue -is [DateTime]) {",
                "if ($false) {",
            ),
            (
                "$readyProcessStartValue.ToUniversalTime()",
                "[DateTime]::MinValue",
            ),
            (
                "[DateTimeOffset]::Parse(",
                "[DateTime]::Parse(",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                runner = self.runner.replace(original, replacement)
                self.assertNotEqual(runner, self.runner)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    def test_requires_anchored_ordered_forwarder_command_identity(self) -> None:
        expected = (
            "forwarder process identity must use one anchored, ordered "
            "executable/script/--config command line with no decoy arguments"
        )
        mutations = (
            (
                '"^\\s*" +',
                '"\\s*" +',
            ),
            (
                '"\\s*$"',
                '"\\s*"',
            ),
            (
                "Test-LanForwarderCommandLine `",
                "Removed-LanForwarderCommandLine `",
            ),
            (
                "accepted a decoy command line",
                "accepted an unrelated command line",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                runner = self.runner.replace(original, replacement)
                self.assertNotEqual(runner, self.runner)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    @unittest.skipUnless(
        WINDOWS_POWERSHELL,
        "Windows PowerShell is required for this runtime self-test",
    )
    def test_forwarder_command_identity_rejects_decoy_arguments_at_runtime(
        self,
    ) -> None:
        function_sources = "\n".join(
            f"function {name} {{"
            f"{_function_body(self.runner, name)}"
            for name in (
                "Get-ExactCommandLineValuePattern",
                "Test-LanForwarderCommandLine",
            )
        )
        driver = r"""
$ErrorActionPreference = "Stop"
$forwarder = [PSCustomObject]@{
    nodeExecutablePath = "C:\Program Files\nodejs\node.exe"
    scriptPath = "C:\Release State\lan_release_forwarder.mjs"
    configPath = "C:\Release State\lan-forwarder.config.json"
}
$validCommandLines = @(
    '"C:\Program Files\nodejs\node.exe" "C:\Release State\lan_release_forwarder.mjs" --config "C:\Release State\lan-forwarder.config.json"',
    '"C:\Program Files\nodejs\node.exe" "C:\Release State\lan_release_forwarder.mjs" --config="C:\Release State\lan-forwarder.config.json"'
)
foreach ($commandLine in $validCommandLines) {
    if (-not (Test-LanForwarderCommandLine `
        -CommandLine $commandLine `
        -Forwarder $forwarder)) {
        throw "valid exact command line was rejected: $commandLine"
    }
}
$invalidCommandLines = @(
    'decoy "C:\Program Files\nodejs\node.exe" "C:\Release State\lan_release_forwarder.mjs" --config "C:\Release State\lan-forwarder.config.json"',
    '"C:\Program Files\nodejs\node.exe" --inspect "C:\Release State\lan_release_forwarder.mjs" --config "C:\Release State\lan-forwarder.config.json"',
    '"C:\Program Files\nodejs\node.exe" "C:\Release State\lan_release_forwarder.mjs" --config "C:\Release State\lan-forwarder.config.json" --inspect',
    '"C:\Program Files\nodejs\node.exe.bak" "C:\Release State\lan_release_forwarder.mjs" --config "C:\Release State\lan-forwarder.config.json"',
    '"C:\Program Files\nodejs\node.exe" "C:\Release State\lan_release_forwarder.mjs.bak" --config "C:\Release State\lan-forwarder.config.json"',
    '"C:\Program Files\nodejs\node.exe" "C:\Release State\lan_release_forwarder.mjs" --config "C:\Release State\lan-forwarder.config.json.bak"',
    '"C:\Program Files\nodejs\node.exe" --config "C:\Release State\lan-forwarder.config.json" "C:\Release State\lan_release_forwarder.mjs"'
)
foreach ($commandLine in $invalidCommandLines) {
    if (Test-LanForwarderCommandLine `
        -CommandLine $commandLine `
        -Forwarder $forwarder) {
        throw "decoy command line was accepted: $commandLine"
    }
}
$plainForwarder = [PSCustomObject]@{
    nodeExecutablePath = "C:\node\node.exe"
    scriptPath = "C:\state\lan_release_forwarder.mjs"
    configPath = "C:\state\lan-forwarder.config.json"
}
foreach ($commandLine in @(
    'C:\node\node.exe C:\state\lan_release_forwarder.mjs --config C:\state\lan-forwarder.config.json',
    '"C:\node\node.exe" "C:\state\lan_release_forwarder.mjs" --config="C:\state\lan-forwarder.config.json"'
)) {
    if (-not (Test-LanForwarderCommandLine `
        -CommandLine $commandLine `
        -Forwarder $plainForwarder)) {
        throw "valid no-whitespace-path command line was rejected: $commandLine"
    }
}
if (Test-LanForwarderCommandLine `
    -CommandLine (
        'C:\node\node.exe C:\state\lan_release_forwarder.mjs ' +
        '--config C:\state\lan-forwarder.config.json.bak'
    ) `
    -Forwarder $plainForwarder) {
    throw "no-whitespace-path suffix decoy was accepted"
}
Write-Output "strict forwarder command identity runtime self-test passed"
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            test_script_path = (
                Path(temporary_directory) / "forwarder-command-self-test.ps1"
            )
            test_script_path.write_text(
                function_sources + driver,
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    WINDOWS_POWERSHELL,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(test_script_path),
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
                "strict forwarder command identity runtime self-test passed",
                result.stdout,
            )

    def test_requires_forwarder_start_stop_and_cleanup_controls(self) -> None:
        expected = (
            "forwarder lifecycle must replace only receipt-owned processes, "
            "retain hidden-process logs, and prove failed-start and stop cleanup "
            "released every public listener"
        )
        mutations = (
            (
                "-WindowStyle Hidden",
                "-WindowStyle Normal",
            ),
            (
                "Get-VerifiedLanForwarderCommandProcess",
                "Removed-VerifiedLanForwarderCommandProcess",
            ),
            (
                "Assert-LanForwarderPortsReleased -Receipt $Receipt",
                "Write-Warning 'listener release not verified'",
            ),
            (
                "elseif ($commandProcesses.Count -eq 1)",
                "elseif ($false)",
            ),
            (
                "[int]$_.OwningProcess -ne $exactProcessId",
                "$false",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                runner = self.runner.replace(original, replacement)
                self.assertNotEqual(runner, self.runner)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    def test_restore_validates_target_image_before_stopping_active_forwarder(
        self,
    ) -> None:
        image_evidence = (
            "$image = Get-ImageEvidence `\n"
            "        -ImageReference $Receipt.imageReference `"
        )
        premature_stop = (
            "Stop-LanForwarder -Receipt $activeReceipt -AllowNotRunning\n\n"
            "    " + image_evidence
        )
        runner = self.runner.replace(image_evidence, premature_stop)
        self.assertNotEqual(runner, self.runner)
        self.assertIn(
            "Restore must validate the target image revision, ID, and digest "
            "before stopping the active receipt's forwarder",
            validate_local_release(self.compose, runner),
        )

    def test_start_recovers_forwarder_only_after_retained_image_validation(
        self,
    ) -> None:
        expected = (
            "Start must validate the retained image revision, ID, and digest, "
            "then stale-safely stop its forwarder before candidate port preflight"
        )
        image_evidence = (
            "$retainedImage = Get-ImageEvidence `\n"
            "        -ImageReference $current.imageReference `"
        )
        premature_stop = (
            "Stop-LanForwarder -Receipt $current -AllowNotRunning\n\n"
            "    " + image_evidence
        )
        mutations = (
            self.runner.replace(image_evidence, premature_stop),
            self.runner.replace(
                "    Stop-LanForwarder -Receipt $current -AllowNotRunning\n\n"
                "    Assert-CandidatePorts `",
                "    Assert-CandidatePorts `",
                1,
            ),
        )
        for runner in mutations:
            with self.subTest():
                self.assertNotEqual(runner, self.runner)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    def test_requires_forwarder_calls_across_every_release_lifecycle(
        self,
    ) -> None:
        expected = (
            "Deploy, Restore, Start, Rollback, and Stop must manage the "
            "receipt-bound forwarder, including failure cleanup, with Node "
            "required only for LAN mode"
        )
        mutations = (
            (
                (
                    "    Assert-RetainedReleaseAssets -Receipt $current\n"
                    "    Unregister-LanForwarderSupervisor `\n"
                    "        -Receipt $current `\n"
                    "        -AllowNotRegistered\n"
                    "    Stop-LanForwarder -Receipt $current -AllowNotRunning\n"
                    "    Ensure-PodmanReady"
                ),
                (
                    "    Assert-RetainedReleaseAssets -Receipt $current\n"
                    "    Unregister-LanForwarderSupervisor `\n"
                    "        -Receipt $current `\n"
                    "        -AllowNotRegistered\n"
                    "    Write-Warning 'forwarder left running'\n"
                    "    Ensure-PodmanReady"
                ),
            ),
            (
                (
                    "                Stop-LanForwarder `\n"
                    "                    -Receipt $candidateForwarderReceipt `"
                ),
                (
                    "                Removed-CandidateForwarderCleanup `\n"
                    "                    -Receipt $candidateForwarderReceipt `"
                ),
            ),
            (
                (
                    "if ($script:BindAddress -cne $podmanBindAddress) {\n"
                    '        $requiredCommands += "node"\n'
                    "    }"
                ),
                (
                    "if ($false) {\n"
                    '        $requiredCommands += "node"\n'
                    "    }"
                ),
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                runner = self.runner.replace(original, replacement)
                self.assertIn(
                    expected,
                    validate_local_release(self.compose, runner),
                )

    def test_requires_forwarder_status_and_executable_self_tests(self) -> None:
        missing_status = self.runner.replace(
            "Observed forwarder configuration hash matches receipt:",
            "Forwarder configuration was recorded:",
        )
        self.assertIn(
            "Status must report the exact forwarder readiness, receipt-identity, "
            "configuration-hash, and listener-ownership evidence consumed by "
            "qualification",
            validate_local_release(self.compose, missing_status),
        )

        missing_self_test = self.runner.replace(
            "        Invoke-LanForwarderSelfTest "
            "-TemporaryDirectory $temporaryDirectory",
            "        Write-Warning 'forwarder self-test removed'",
        )
        self.assertIn(
            "local release validation must exercise forwarder asset, READY, "
            "process-replacement, orphan-cleanup, occupied-port, and "
            "listener-release controls",
            validate_local_release(self.compose, missing_self_test),
        )

    def test_rejects_public_probe_before_local_health_and_forwarder_ready(
        self,
    ) -> None:
        marker = (
            "        Ensure-InstantRoomTenant `\n"
            "            -EnvironmentFile $environmentFile `"
        )
        premature_public_probe = (
            "        Wait-Application `\n"
            "            -ExpectedBindAddress $BindAddress `\n"
            "            -ExpectedAppPort $AppPort `\n"
            "            -ExpectedMinioPort $MinioPort `\n"
            "            -ExpectedLiveKitPort $LiveKitSignalPort\n"
        )
        runner = self.runner.replace(
            marker,
            premature_public_probe + marker,
        )
        self.assertIn(
            "deployment and restore must prove loopback Podman bootstrap and "
            "health before activating, identity-checking, and publicly probing "
            "a required LAN forwarder",
            validate_local_release(self.compose, runner),
        )

    def test_requires_status_network_match_and_pre_compose_drift_guards(self) -> None:
        runner = self.runner.replace(
            "function Invoke-StartLocked {\n    $current = Get-CurrentReceipt",
            "function Invoke-StartLocked {\n"
            "    Assert-CandidatePorts\n"
            "    $current = Get-CurrentReceipt",
        ).replace(
            "function Invoke-RollbackLocked {\n    $current = Get-CurrentReceipt",
            "function Invoke-RollbackLocked {\n"
            "    Assert-GuestRollbackSafe\n"
            "    $current = Get-CurrentReceipt",
        ).replace(
            "Observed network topology matches receipt:",
            "Recorded network topology only:",
        ).replace(
            "$networkTopologyMatchesReceipt = $true",
            "$networkTopologyMatchesReceipt = $false",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "Status must re-observe and expose an explicit receipt-network match, "
            "and Rollback must revalidate both retained network topologies",
            errors,
        )
        self.assertIn(
            "Start must reject retained network drift before any Compose-capable "
            "port, rollback-safety, or restore action",
            errors,
        )
        self.assertIn(
            "Rollback must reject current or target network drift before any "
            "Compose-capable rollback-safety or restore action",
            errors,
        )

    def test_requires_release_environment_topology_assertion(self) -> None:
        runner = self.runner.replace(
            "        Assert-ReleaseEnvironmentTopology `",
            "        RemovedEnvironmentTopologyAssertion `",
        ).replace(
            "K_COMMS_LOCAL_RELEASE_HOST = $expectedRuntimeHost",
            "K_COMMS_LOCAL_RELEASE_HOST = $ExpectedBindAddress",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "deploy and validation must assert the complete loopback or LAN "
            "release-environment topology before Compose rendering",
            errors,
        )

    def test_rejects_podman_incompatible_loopback_candidate_flag(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["livekit"]["command"].append(
            "--rtc.enable_loopback_candidate"
        )
        errors = validate_local_release(document, self.runner)
        self.assertIn(
            "service 'livekit' must not enable the explicit loopback candidate "
            "flag because it prevents Podman Desktop TCP media negotiation",
            errors,
        )

    def test_requires_runtime_validation_of_the_pinned_livekit_flags(self) -> None:
        runner = self.runner.replace("help-verbose", "removed-livekit-help")
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "local release validation must inspect the exact pinned LiveKit flag surface",
            errors,
        )

    def test_rejects_different_migration_image_or_down_migration(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["migrate"]["image"] = "localhost/k-comms:old"
        runner = self.runner + "\nCommsCore.Release.rollback(CommsCore.Repo, 1)\n"
        errors = validate_local_release(document, runner)
        self.assertIn(
            "migration and application services must use the same exact image", errors
        )
        self.assertIn(
            "local release orchestration must never run down migrations", errors
        )

    def test_requires_bounded_quiesced_forward_migrations(self) -> None:
        document = copy.deepcopy(self.compose)
        del document["services"]["migrate"]["environment"][
            "K_COMMS_MIGRATION_REQUIRE_QUIESCENCE"
        ]
        errors = validate_local_release(document, self.runner)
        self.assertTrue(
            any(
                "K_COMMS_MIGRATION_REQUIRE_QUIESCENCE=true" in error
                for error in errors
            )
        )

    def test_one_shot_services_clear_trusted_edge_application_context(self) -> None:
        for service_name in ("migrate", "bootstrap", "qualification"):
            for environment_name in (
                "K_COMMS_RELEASE_EXPOSURE_MODE",
                "K_COMMS_TRUSTED_EDGE_CONFIRMATION",
            ):
                with self.subTest(
                    service=service_name,
                    environment=environment_name,
                ):
                    document = copy.deepcopy(self.compose)
                    document["services"][service_name]["environment"][
                        environment_name
                    ] = f"${{{environment_name}:-inherited}}"

                    errors = validate_local_release(document, self.runner)

                    self.assertTrue(
                        any(environment_name in error for error in errors),
                        errors,
                    )

        runner = self.runner.replace(
            "        Stop-ApplicationForMigration `",
            '        Write-Warning "migration quiescence removed"',
            1,
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "forward migrations must stop and verify the application before "
            "the bounded migration runner starts",
            errors,
        )

    def test_rejects_missing_state_ownership_or_reparse_guards(self) -> None:
        runner = self.runner.replace(
            ".k-comms-local-release-state-v1.json", "removed-state-marker"
        ).replace("ReparsePoint", "RemovedReparseGuard")
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "local release orchestrator must require a tool-owned state marker", errors
        )
        self.assertIn(
            "local release orchestrator must reject reparse-point state roots and markers",
            errors,
        )
        self.assertIn(
            "custom state roots must reject every existing reparse-point ancestor",
            errors,
        )

    def test_rejects_custom_state_root_without_ancestor_walk(self) -> None:
        runner = self.runner.replace(
            "$customStateRootRequested", "$removedCustomStateRootGuard"
        ).replace("$current = $current.Parent", "$current = $null").replace(
            "[IO.File]::GetAttributes", "[IO.File]::GetLastWriteTime"
        ).replace(
            "$_.Exception.InnerException", "$null"
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "custom state-root validation must inspect all existing ancestors", errors
        )
        self.assertIn(
            "custom state-root ancestor validation must inspect path entries through "
            "the filesystem root and reject reparse points",
            errors,
        )

    def test_rejects_state_root_without_post_create_and_pre_acl_revalidation(
        self,
    ) -> None:
        runner = self.runner.replace(
            "function Protect-StateDirectory {\n"
            "    param([Parameter(Mandatory)][string]$Path)\n\n"
            "    # Re-check the complete custom path immediately before changing ACLs. The\n"
            "    # directory may have been created since the initial validation, and an\n"
            "    # ancestor must not have been replaced with a junction in that interval.\n"
            "    Assert-SafeStateRootPath -Path $Path",
            "function Protect-StateDirectory {\n"
            "    param([Parameter(Mandatory)][string]$Path)",
        )
        runner = runner.replace(
            "    New-Item -ItemType Directory -Path $Path | Out-Null\n"
            "    # Validate again after creation and before writing the ownership marker.\n"
            "    # This closes the gap where a custom ancestor could be replaced while the\n"
            "    # previously non-existent state path was being created.\n"
            "    Assert-SafeStateRootPath -Path $Path",
            "    New-Item -ItemType Directory -Path $Path | Out-Null",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "state-root paths must be revalidated after creation and immediately "
            "before ACL mutation",
            errors,
        )

    def test_rejects_state_root_self_test_that_bypasses_custom_initialization(
        self,
    ) -> None:
        runner = self.runner.replace(
            "Initialize-OwnedStateDirectory `\n"
            "                -Path $nestedUnderJunction `",
            "Assert-NoReparsePointAncestors `\n"
            "                -Path $nestedUnderJunction `",
        ).replace(
            "$script:customStateRootRequested = $true",
            "$script:customStateRootRequested = $false",
        ).replace(
            "-Path $safeCustomPath",
            "-Path $temporaryParent",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "state-root self-test must exercise rejected junction traversal and "
            "accepted non-existent custom-path initialization",
            errors,
        )

    def test_rejects_missing_exclusive_operation_locks(self) -> None:
        runner = self.runner.replace("[IO.FileShare]::None", "[IO.FileShare]::Read")
        runner = runner.replace("Local\\KComms.LocalRelease.", "RemovedProjectMutex.")
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "local release orchestrator must hold an exclusive state operation lock",
            errors,
        )
        self.assertIn(
            "local release orchestrator must hold a Compose-project operation mutex",
            errors,
        )

    def test_rejects_restore_that_uses_checkout_compose(self) -> None:
        runner = self.runner.replace(
            "-ComposePath $Receipt.composeSourcePath", "-ComposePath $composeFile"
        )
        runner = runner.replace("environmentSha256", "removedEnvironmentHash")
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "local release orchestrator must hash the retained release environment",
            errors,
        )
        self.assertIn(
            "restore and lifecycle operations must use the retained Compose source",
            errors,
        )

    def test_rejects_revision_only_mutable_candidate_tag(self) -> None:
        runner = self.runner.replace("$candidateNonce", "$removedAttemptId")
        runner += '\n$imageReference = "localhost/k-comms:sha-$revision"\n'
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "release image tags must include a unique candidate attempt identifier",
            errors,
        )
        self.assertIn(
            "release image tags must be unique per candidate so a repeated revision "
            "cannot invalidate predecessor rollback",
            errors,
        )

    def test_requires_guest_capability_only_for_the_candidate(self) -> None:
        candidate_without_guest_check = self.runner.replace(
            "            -RequireGuestLinks `",
            "            -RemovedGuestLinks `",
        )
        errors = validate_local_release(self.compose, candidate_without_guest_check)
        self.assertIn(
            "candidate deployment must require the guest-links capability before sealing",
            errors,
        )

        restore_with_candidate_capability = self.runner.replace(
            "        -ExpectedLiveKitPort ([int]$Receipt.ports.livekitSignal)",
            "        -ExpectedLiveKitPort ([int]$Receipt.ports.livekitSignal) `\n"
            "        -RequireGuestLinks",
        )
        errors = validate_local_release(
            self.compose, restore_with_candidate_capability
        )
        self.assertIn(
            "predecessor restore must not require capabilities introduced by the candidate",
            errors,
        )

        missing_runtime_self_test = self.runner.replace(
            "        Invoke-CapabilityCompatibilitySelfTest",
            '        Write-Host "capability compatibility self-test removed"',
        )
        errors = validate_local_release(self.compose, missing_runtime_self_test)
        self.assertIn(
            "release validation must execute predecessor and candidate capability self-tests",
            errors,
        )

    def test_guest_migrations_are_additive(self) -> None:
        identity_migration = (
            ROOT
            / "apps"
            / "comms_core"
            / "priv"
            / "repo"
            / "migrations"
            / "20260724000160_add_guest_identity_expiry.exs"
        ).read_text(encoding="utf-8")
        access_migration = (
            ROOT
            / "apps"
            / "comms_core"
            / "priv"
            / "repo"
            / "migrations"
            / "20260724000170_add_conversation_guest_access.exs"
        ).read_text(encoding="utf-8")

        # The forward schema keeps existing human/service rows valid, changes
        # existing tables only with nullable or defaulted columns, and adds
        # guest-owned tables. Persisted guest rows still require the explicit
        # rollback-compatibility guard tested below.
        self.assertIn(
            'check: "account_type IN (\'human\', \'service\', \'guest\')"',
            identity_migration,
        )
        self.assertIn("add(:guest_expires_at, :utc_datetime_usec)", identity_migration)
        self.assertIn(
            "add(:access_scope, :map, null: false, default: %{})",
            identity_migration,
        )
        self.assertIn(
            "create table(:conversation_guest_links",
            access_migration,
        )
        self.assertIn(
            "create table(:conversation_guest_admissions",
            access_migration,
        )
        for migration in (identity_migration, access_migration):
            up_body = migration.split("def up do", 1)[1].split("def down do", 1)[0]
            self.assertNotIn("remove(", up_body)
            self.assertNotIn("drop(table(", up_body)

    def test_requires_guest_rollback_compatibility_guard(self) -> None:
        missing_receipt_capability = self.runner.replace(
            '                "guest_identity_v1"\n'
            '                "guest_admission_expiry_worker_v1"',
            '                "removed_guest_rollback_capabilities"',
            1,
        )
        errors = validate_local_release(self.compose, missing_receipt_capability)
        self.assertIn(
            "release receipts must declare guest identity and expiry-worker "
            "rollback compatibility",
            errors,
        )

        missing_hazard_probe = self.runner.replace(
            "WHERE worker = 'CommsWorkers.GuestAdmissionExpiryWorker'",
            "WHERE worker = 'RemovedGuestExpiryWorker'",
        )
        errors = validate_local_release(self.compose, missing_hazard_probe)
        self.assertIn(
            "guest rollback preflight must query persisted guest identities and "
            "active expiry jobs",
            errors,
        )

        missing_manual_guard = self.runner.replace(
            "    Assert-GuestRollbackSafe `\n"
            "        -CurrentReceipt $current `\n"
            "        -TargetReceipt $target `\n"
            "        -RestoreCurrentOnFailure",
            '    Write-Warning "guest rollback guard removed"',
        )
        errors = validate_local_release(self.compose, missing_manual_guard)
        self.assertIn(
            "manual and post-migration automatic rollback must guard legacy "
            "predecessors before restore",
            errors,
        )

        missing_quiescence = self.runner.replace(
            '        -Arguments @("stop", "app") `',
            '        -Arguments @("ps", "app") `',
        )
        errors = validate_local_release(self.compose, missing_quiescence)
        self.assertIn(
            "legacy guest rollback preflight must quiesce and verify the current "
            "application",
            errors,
        )

        missing_current_restart = self.runner.replace(
            "                    Restore-Release -Receipt $CurrentReceipt "
            "-UpdatePointer",
            '                    Write-Warning "current restart removed"',
        )
        errors = validate_local_release(self.compose, missing_current_restart)
        self.assertIn(
            "guest rollback preflight must quiesce legacy writes, evaluate hazards, "
            "and restore the current receipt on a manual block",
            errors,
        )

        stale_legacy_reactivation = self.runner.replace(
            "recorded current receipt also lacks",
            "recorded current receipt was ignored",
        )
        errors = validate_local_release(self.compose, stale_legacy_reactivation)
        self.assertIn(
            "guest rollback preflight must quiesce legacy writes, evaluate hazards, "
            "and restore the current receipt on a manual block",
            errors,
        )

        missing_target_failure_recovery = self.runner.replace(
            "function Restore-RollbackTargetOrCurrent {",
            "function RemovedRollbackTargetRecovery {",
        )
        errors = validate_local_release(
            self.compose, missing_target_failure_recovery
        )
        self.assertIn(
            "manual rollback must recover the exact current receipt when target "
            "restore fails",
            errors,
        )

        missing_self_test = self.runner.replace(
            "        Invoke-GuestRollbackCompatibilitySelfTest",
            '        Write-Host "guest rollback self-test removed"',
        )
        errors = validate_local_release(self.compose, missing_self_test)
        self.assertIn(
            "release validation must exercise guest rollback compatibility self-tests",
            errors,
        )

    def test_requires_instant_room_rollback_compatibility_guard(self) -> None:
        missing_capability = self.runner.replace(
            '"instant_room_lifecycle_v1"',
            '"removed_instant_room_lifecycle_v1"',
        )
        errors = validate_local_release(self.compose, missing_capability)
        self.assertIn(
            "release receipts and rollback guard must declare every instant-room "
            "persistence and worker compatibility capability",
            errors,
        )

        missing_room_probe = self.runner.replace(
            "conversation_ephemeral_rooms",
            "removed_ephemeral_rooms",
        )
        errors = validate_local_release(self.compose, missing_room_probe)
        self.assertIn(
            "communication rollback preflight must fail-safely query instant rooms, "
            "join receipts, presence leases, conversation-only humans, and active "
            "lifecycle jobs",
            errors,
        )

        missing_receipt_probe = self.runner.replace(
            "conversation_ephemeral_join_receipts",
            "removed_ephemeral_join_receipts",
        )
        errors = validate_local_release(self.compose, missing_receipt_probe)
        self.assertIn(
            "communication rollback preflight must fail-safely query instant rooms, "
            "join receipts, presence leases, conversation-only humans, and active "
            "lifecycle jobs",
            errors,
        )

    def test_rejects_missing_first_failure_cleanup_or_runtime_observation(self) -> None:
        runner = self.runner.replace(
            "Remove-FailedCandidateRuntime", "RemovedCandidateCleanup"
        ).replace("Observed application state", "Recorded application state")
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "a failed first deployment must clean up its complete candidate runtime",
            errors,
        )
        self.assertIn(
            "status must distinguish recorded release evidence from observed runtime state",
            errors,
        )

    def test_rejects_mutable_checkout_build_or_missing_head_guarantees(self) -> None:
        runner = self.runner.replace(
            '"archive",\n            "--format=tar",',
            '"status",\n            "--porcelain=v1",',
        )
        runner = runner.replace(
            "-WorkingDirectory $source.contextPath `\n", ""
        )
        runner = runner.replace(
            'Assert-RepositoryHead `\n'
            "            -ExpectedRevision $Revision `\n"
            '            -Phase "after building the immutable candidate image"',
            "Write-Host \"post-build HEAD check removed\"",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "immutable release source must be created with git archive", errors
        )
        self.assertIn(
            "release image build must use the isolated immutable source context",
            errors,
        )
        self.assertIn(
            "release image build must verify repository HEAD after the immutable build",
            errors,
        )

    def test_rejects_partial_or_unverified_first_candidate_cleanup(self) -> None:
        runner = self.runner.replace('        "postgres"\n', "")
        runner = runner.replace(
            '-Arguments @("ps", "--all", "--quiet")',
            '-Arguments @("ps", "--quiet")',
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "first-candidate failure cleanup must include service 'postgres'", errors
        )
        self.assertIn(
            "first-candidate failure cleanup must verify that no candidate containers remain",
            errors,
        )

    def test_rejects_missing_executable_first_candidate_cleanup_self_test(
        self,
    ) -> None:
        runner = self.runner.replace(
            "        Invoke-FailedCandidateCleanupSelfTest",
            "        Write-Host \"cleanup self-test removed\"",
        ).replace(
            "-ComposeInvoker $successfulInvoker",
            "-ComposeInvoker $remainingInvoker",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "local release validation must execute first-candidate cleanup self-tests",
            errors,
        )
        self.assertIn(
            "first-candidate cleanup must have an executable self-test for complete "
            "service removal and remaining-container rejection",
            errors,
        )

    def test_rejects_environment_parser_incompatible_with_powershell_51(self) -> None:
        runner = self.runner.replace(
            '$separatorIndex = $line.IndexOf("=")',
            '$parts = $line.Split(@("="), 2)',
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "environment-file parsing must use PowerShell 5.1-compatible index and "
            "substring operations",
            errors,
        )

    def test_rejects_unsuppressed_podman_compose_provider_banner(self) -> None:
        runner = self.runner.replace(
            '$env:PODMAN_COMPOSE_WARNING_LOGS = "false"',
            '$env:PODMAN_COMPOSE_WARNING_LOGS = "true"',
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "Podman Compose provider warnings must be suppressed before parsing "
            "machine-readable command output",
            errors,
        )

    def test_rejects_late_or_incomplete_candidate_port_preflight(self) -> None:
        runner = self.runner.replace(
            "    Assert-CandidatePorts `\n"
            "        -CandidateBindAddress $BindAddress `\n"
            "        -CandidateAppPort $AppPort `",
            "    Assert-RemovedCandidatePorts `\n"
            "        -CandidateBindAddress $BindAddress `\n"
            "        -CandidateAppPort $AppPort `",
        )
        runner = runner.replace("Group-Object -Property Port", "Group-Object -Property Name")
        runner = runner.replace(
            "Test-RetainedServiceOwnsPort", "RemovedRetainedPortOwnershipCheck"
        )
        runner = runner.replace(
            "Test-RetainedForwarderOwnsPort",
            "RemovedRetainedForwarderOwnershipCheck",
        )
        runner = runner.replace(
            "            BindAddress = $podmanBindAddress",
            "            BindAddress = $CandidateBindAddress",
            1,
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "candidate port uniqueness and availability must be checked before image build",
            errors,
        )
        self.assertIn(
            "candidate port preflight must enforce uniqueness, loopback-only "
            "Podman and MinIO-console availability, and exact selected-address "
            "TCP/UDP forwarder availability",
            errors,
        )
        self.assertIn(
            "candidate port preflight must only exempt verified Podman mappings "
            "or ready receipt-bound forwarder listeners owned by the retained release",
            errors,
        )

    def test_rejects_start_that_rebuilds_or_skips_retained_validation(self) -> None:
        runner = self.runner.replace(
            '"Start" { Invoke-Start }', '"Start" { Invoke-RemovedStart }'
        )
        runner = runner.replace(
            "function Invoke-StartLocked {\n    $current = Get-CurrentReceipt",
            'function Invoke-StartLocked {\n    "build",\n'
            "    $current = Get-CurrentReceipt",
        )
        runner = runner.replace("$Receipt.imageDigest", "$Receipt.removedDigest")
        runner = runner.replace(
            "Assert-ImmutableRestartReceipt", "RemovedImmutableRestartReceiptCheck"
        )
        runner = runner.replace(
            "            -RunMigration `\n            -UpdatePointer",
            "            -UpdatePointer",
        )
        runner = runner.replace(
            "        Assert-GuestRollbackSafe `\n"
            "            -CurrentReceipt $current `\n"
            "            -TargetReceipt $current\n",
            "",
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "local release actions must expose the supported Start lifecycle action",
            errors,
        )
        self.assertIn(
            "Start must restart the current retained receipt with forward migration "
            "and health checks",
            errors,
        )
        self.assertIn(
            "Start must fail closed before activating a guest-incompatible retained receipt",
            errors,
        )
        self.assertIn(
            "Start must never rebuild or depend on mutable checkout source", errors
        )
        self.assertIn(
            "retained release startup must validate assets, image identity, digest, "
            "and use its retained migration path",
            errors,
        )

    def test_requires_trusted_edge_compose_interpolation(self) -> None:
        document = copy.deepcopy(self.compose)
        document["services"]["app"]["environment"].pop(
            "K_COMMS_RELEASE_EXPOSURE_MODE"
        )
        document["services"]["app"]["environment"].pop("HSTS_ENABLED")
        document["services"]["app"]["environment"].pop("TRUSTED_PROXY_CIDRS")
        document["services"]["livekit"]["command"] = [
            (
                "${K_COMMS_RELEASE_HOST:-127.0.0.1}"
                if value == "${K_COMMS_LIVEKIT_NODE_IP:-127.0.0.1}"
                else value
            )
            for value in document["services"]["livekit"]["command"]
        ]
        errors = validate_local_release(document, self.runner)
        self.assertTrue(
            any(
                "K_COMMS_RELEASE_EXPOSURE_MODE="
                "${K_COMMS_RELEASE_EXPOSURE_MODE:-}" in error
                for error in errors
            )
        )
        self.assertTrue(
            any(
                "${K_COMMS_LIVEKIT_NODE_IP:-127.0.0.1}" in error
                for error in errors
            )
        )
        for variable in ("HSTS_ENABLED", "TRUSTED_PROXY_CIDRS"):
            self.assertTrue(
                any(variable in error for error in errors),
                f"{variable} interpolation was not enforced",
            )

    def test_rejects_incomplete_cloudflare_trusted_edge_contract(self) -> None:
        mutations = {
            "CLI profile": (
                '[ValidateSet("auto", "cloudflare_trusted_edge")]',
                '[ValidateSet("auto")]',
            ),
            "canonical HTTPS app origin": (
                'PublicAppUrl = "https://$resolvedAppHostname"',
                'PublicAppUrl = "http://$resolvedAppHostname"',
            ),
            "exact trusted-edge confirmation": (
                "if ($TrustedEdgeConfirmation -cne "
                "$cloudflareTrustedEdgeConfirmation) {",
                "if ($false) {",
            ),
            "canonical lowercase hostname": (
                "$Value -cne $Value.ToLowerInvariant() -or",
                "$false -or",
            ),
            "non-loopback media node": (
                "if ($observation.BindAddress -ceq $podmanBindAddress) {",
                "if ($false) {",
            ),
            "RFC1918 proxy requirement": (
                "-not (Test-Rfc1918IPv4 -Address $parsed)",
                "$false",
            ),
            "sealed Podman network ID": (
                '$networkId -notmatch "^[0-9a-f]{64}$"',
                "$false",
            ),
            "schema-v7 receipt": (
                "schemaVersion = 7",
                "schemaVersion = 6",
            ),
            "schema-v6 deploy replacement": (
                "$previousTrustedSchemaVersion -eq 7",
                "$previousTrustedSchemaVersion -ge 6",
            ),
            "app-self source kind": (
                '$trustedProxySourceKind = "podman-app-self-v1"',
                '$trustedProxySourceKind = "removed"',
            ),
            "stopped no-deps reservation": (
                '            "--no-start",',
                '            "--removed-no-start",',
            ),
            "exact app IP rebind": (
                '    $connectArguments = @('
                '\n        "network",'
                '\n        "connect",'
                '\n        "--ip",',
                '    $connectArguments = @('
                '\n        "network",'
                '\n        "connect",'
                '\n        "--removed-ip",',
            ),
            "foreign IP preflight before disconnect": (
                "    $null = Assert-TrustedProxyRecoveryOccupancy `"
                "\n        -ExpectedAddress $contract.ApplicationContainerIpv4 `"
                "\n        -Allocations @($contract.Network.Allocations) `"
                "\n        -ApplicationContainerId $containerId `"
                "\n        -ApplicationAttachedAddress $original.IPAddress `"
                "\n        -ApplicationRunning $false",
                "    $null = Removed-TrustedProxyRecoveryOccupancy `"
                "\n        -ExpectedAddress $contract.ApplicationContainerIpv4 `"
                "\n        -Allocations @($contract.Network.Allocations) `"
                "\n        -ApplicationContainerId $containerId `"
                "\n        -ApplicationAttachedAddress $original.IPAddress `"
                "\n        -ApplicationRunning $false",
            ),
            "Compose app ownership": (
                '"com.docker.compose.service"',
                '"removed.compose.service"',
            ),
            "Compose network ownership": (
                "[string]$projectLabelProperty.Value -cne "
                "$ExpectedComposeProject",
                "$false",
            ),
            "deleted app recovery": (
                "Deleted application was not accepted for exact-IP recovery",
                "Removed deleted application recovery proof",
            ),
            "stopped app recovery": (
                "Stopped application was not accepted for exact-IP recovery",
                "Removed stopped application recovery proof",
            ),
            "absent app preflight": (
                "        -AllowNotFound",
                "        -RemovedAllowNotFound",
            ),
            "sealed application IPv4": (
                '$record["applicationContainerIpv4"] =',
                '$record["removedApplicationContainerIpv4"] =',
            ),
            "sealed application hostname": (
                '$record["appHostname"] = [string]$Observation.PublicHost',
                '$record["removedAppHostname"] = [string]$Observation.PublicHost',
            ),
            "trusted exposure replay": (
                "if ($recordedExposureMode -cne "
                "$cloudflareTrustedEdgeProfile) {",
                "if ($false) {",
            ),
            "trusted media-only replay": (
                "if (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt) {",
                "if ($false) {",
            ),
            "trusted-edge rollback gate": (
                "Assert-RollbackExposureTopologyCompatible `",
                "Removed-RollbackExposureTopologyCompatible `",
            ),
            "rollback topology comparison": (
                "if ($comparison[1] -cne $comparison[2]) {",
                "if ($false) {",
            ),
        }
        expected = (
            "Cloudflare trusted-edge releases must seal canonical HTTPS/WSS "
            "origins, one schema-v7 RFC1918 Podman app-self /32, exact network "
            "and ownership evidence, stopped reservation before one-shots, "
            "media-only forwarding, public health probes, and fail-closed "
            "restart/rollback topology"
        )
        for description, (before, after) in mutations.items():
            with self.subTest(description=description):
                self.assertIn(before, self.runner)
                errors = validate_local_release(
                    self.compose,
                    self.runner.replace(before, after),
                )
                self.assertIn(expected, errors)

    def test_rejects_missing_media_supervision_or_strict_health(self) -> None:
        expected = (
            "trusted-edge media forwarding must use receipt-bound scheduled "
            "supervision, exact crash recovery, strict health checks, and "
            "fail-closed receipt schema compatibility"
        )
        mutations = (
            (
                "$schemaVersion -gt $supportedReceiptSchemaVersion",
                "$schemaVersion -lt 0",
            ),
            (
                '$retainedSupervisorManagerName = "manage_local_release.supervisor.ps1"',
                '$retainedSupervisorManagerName = "manage_local_release.ps1"',
            ),
            ("Register-ScheduledTask `", "Removed-ScheduledTaskRegistration `"),
            (
                "        $after = Repair-LanForwarderIfNeeded -Receipt $current",
                "        $after = Get-LanForwarderObservation -Receipt $current",
            ),
            (
                '"HealthCheck" { Invoke-HealthCheck }',
                '"HealthCheck" { Invoke-Status }',
            ),
            (
                "        Invoke-LanForwarderSupervisionSelfTest `",
                "        Write-Host 'supervision self-test removed' `",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                self.assertIn(original, self.runner)
                errors = validate_local_release(
                    self.compose,
                    self.runner.replace(original, replacement),
                )
                self.assertIn(expected, errors)

    def test_rejects_supervisor_bootstrap_task_or_publication_regression(
        self,
    ) -> None:
        expected = (
            "trusted-edge supervisor must bootstrap from receipt-only state, "
            "seal immutable manager and PowerShell assets, enforce exact task "
            "identity/schedule/readiness, and publish current only after "
            "registration"
        )
        mutations = (
            (
                "        $ImmutableSourceRoot `\n"
                '        "scripts\\manage_local_release.ps1"',
                "        $repositoryRoot `\n"
                '        "scripts\\manage_local_release.ps1"',
            ),
            (
                "powerShellExecutablePath = Get-CurrentPowerShellExecutablePath",
                'powerShellExecutablePath = Join-Path $PSHOME "powershell.exe"',
            ),
            (
                "    $trigger.Repetition.StopAtDurationEnd = $true",
                "    $trigger.Repetition.StopAtDurationEnd = $false",
            ),
            (
                "        -At $taskStartBoundary.LocalDateTime `",
                "        -At ([DateTime]::Parse('2099-01-01')) `",
            ),
            (
                "            -Value $trigger.StartBoundary",
                "            -Value $Supervisor.taskStartBoundaryUtc",
            ),
            (
                "            $taskInfo = Get-ScheduledTaskInfo `",
                "            $taskInfo = $null # runtime info query removed `",
            ),
            (
                '$TaskInfo.PSObject.Properties["NextRunTime"]',
                '$TaskInfo.PSObject.Properties["LastRunTime"]',
            ),
            (
                "            Set-LanForwarderSupervisorScheduleRecord `",
                "            Write-Host 'schedule sealing removed' `",
            ),
            (
                "            -Value $settings.Enabled `",
                "            -Value $true `",
            ),
            (
                "        Enter-SupervisorOperationLock `",
                "        Enter-ReleaseOperationLock `",
            ),
            (
                "        $current = Get-SupervisorCurrentReceipt `",
                "        $current = Get-CurrentReceipt `",
            ),
            (
                "    if (-not $observation.IdentityMatchesReceipt) {",
                "    if (-not $observation.MatchesReceipt) {",
            ),
            (
                "        $null = Register-LanForwarderSupervisor -Receipt $receipt",
                "        Write-Host 'supervisor registration removed'",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                self.assertIn(original, self.runner)
                errors = validate_local_release(
                    self.compose,
                    self.runner.replace(original, replacement, 1),
                )
                self.assertIn(expected, errors)

    @unittest.skipUnless(
        WINDOWS_POWERSHELL,
        "Windows PowerShell is required for this runtime self-test",
    )
    def test_retained_supervisor_copy_bootstraps_without_repository_context(
        self,
    ) -> None:
        candidate_id = "20260725T000000Z-0123456789ab-01234567"
        config_sha256 = "a" * 64
        project_name = "k-comms-supervisor-child-test"
        with tempfile.TemporaryDirectory() as temporary_directory:
            state_root = Path(temporary_directory) / "receipt state"
            candidate_directory = state_root / "history" / candidate_id
            candidate_directory.mkdir(parents=True)
            retained_manager = (
                candidate_directory / "manage_local_release.supervisor.ps1"
            )
            shutil.copyfile(DEFAULT_RUNNER, retained_manager)
            receipt_path = candidate_directory / "deployment.json"
            manager_sha256 = hashlib.sha256(
                retained_manager.read_bytes()
            ).hexdigest()
            receipt = {
                "schemaVersion": 6,
                "candidateId": candidate_id,
                "receiptPath": str(receipt_path),
                "projectName": project_name,
                "network": {"exposureProfile": "private_lan"},
                "forwarder": {
                    "required": True,
                    "configSha256": config_sha256,
                    "supervisor": {
                        "managerScriptPath": str(retained_manager),
                        "managerScriptSha256": manager_sha256,
                        "expectedReceiptPath": str(receipt_path),
                        "expectedCandidateId": candidate_id,
                        "expectedForwarderConfigSha256": config_sha256,
                    },
                },
            }
            receipt_path.write_text(
                json.dumps(receipt),
                encoding="utf-8",
            )
            (state_root / "current.json").write_text(
                json.dumps({"receiptPath": str(receipt_path)}),
                encoding="utf-8",
            )
            (state_root / ".k-comms-local-release-state-v1.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "kind": "k-comms-local-release-state",
                        "canonicalPath": str(state_root.resolve()),
                        "projectName": project_name,
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    WINDOWS_POWERSHELL,
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(retained_manager),
                    "-Action",
                    "Supervise",
                    "-StateRoot",
                    str(state_root),
                    "-ProjectName",
                    project_name,
                    "-ExpectedReceiptPath",
                    str(receipt_path),
                    "-ExpectedCandidateId",
                    candidate_id,
                    "-ExpectedForwarderConfigSha256",
                    config_sha256,
                    "-ReadyTimeoutSeconds",
                    "30",
                ],
                cwd=Path(temporary_directory),
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn(
                "receipt-bound media supervisor requires trusted-edge mode",
                output,
            )
            for forbidden in (
                "Compose source is missing",
                "Required command is unavailable",
                "dangerous local-release state root",
                "must remain outside the repository",
            ):
                self.assertNotIn(forbidden, output)

    @unittest.skipUnless(
        WINDOWS_POWERSHELL,
        "Windows PowerShell is required for this runtime self-test",
    )
    def test_supervisor_task_contract_rejects_disabled_and_schedule_drift(
        self,
    ) -> None:
        function_sources = "\n".join(
            f"function {name} {{{_function_body(self.runner, name)}"
            for name in (
                "Get-RequiredForwarderProperty",
                "Get-LanForwarderSupervisorTaskArguments",
                "Test-ScheduledTaskDurationEquals",
                "ConvertTo-ScheduledTaskUtcDateTimeOffset",
                "Test-ScheduledTaskNamedValue",
                "Test-ScheduledTaskBoolean",
                "Get-LanForwarderSupervisorTaskContractObservation",
            )
        )
        driver = r"""
$ErrorActionPreference = "Stop"
$now = [DateTimeOffset]::Parse(
    "2026-07-25T00:00:30Z",
    [Globalization.CultureInfo]::InvariantCulture
)
$supervisor = [PSCustomObject]@{
    managerScriptPath = "C:\State\history\candidate\manager.ps1"
    powerShellExecutablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    stateRoot = "C:\State"
    projectName = "k-comms-task-contract-test"
    expectedReceiptPath = "C:\State\history\candidate\deployment.json"
    expectedCandidateId = "20260725T000000Z-0123456789ab-01234567"
    expectedForwarderConfigSha256 = ("a" * 64)
    readyTimeoutSeconds = 30
    intervalSeconds = 60
    scheduleSealedAtUtc = "2026-07-25T00:00:00Z"
    taskStartBoundaryUtc = "2026-07-25T00:00:15Z"
    startDelaySeconds = 15
    repetitionDurationDays = 3650
    nextRunGraceSeconds = 120
    taskDescription = "receipt-bound task"
    principal = "EXAMPLE\operator"
}
function New-TaskFixture {
    $arguments =
        Get-LanForwarderSupervisorTaskArguments -Supervisor $supervisor
    [PSCustomObject]@{
        TaskPath = "\"
        State = "Ready"
        Description = $supervisor.taskDescription
        Actions = @([PSCustomObject]@{
            Execute = $supervisor.powerShellExecutablePath
            Arguments = $arguments
            WorkingDirectory = ""
        })
        Principal = [PSCustomObject]@{
            UserId = $supervisor.principal
            LogonType = "Interactive"
            RunLevel = "Limited"
        }
        Triggers = @([PSCustomObject]@{
            CimClass = [PSCustomObject]@{
                CimClassName = "MSFT_TaskTimeTrigger"
            }
            Enabled = $true
            StartBoundary = $supervisor.taskStartBoundaryUtc
            EndBoundary = ""
            Repetition = [PSCustomObject]@{
                Interval = "PT1M"
                Duration = "P3650D"
                StopAtDurationEnd = $true
            }
        })
        Settings = [PSCustomObject]@{
            Enabled = $true
            MultipleInstances = "IgnoreNew"
            RestartCount = 3
            RestartInterval = "PT30S"
            ExecutionTimeLimit = "PT2M"
            StartWhenAvailable = $true
            AllowDemandStart = $true
            DisallowStartIfOnBatteries = $false
            StopIfGoingOnBatteries = $false
        }
    }
}
$validTaskInfo = [PSCustomObject]@{
    NextRunTime = $now.AddSeconds(45)
}
$valid = Get-LanForwarderSupervisorTaskContractObservation `
    -Task (New-TaskFixture) `
    -Supervisor $supervisor `
    -TaskInfo $validTaskInfo `
    -NowUtc $now
if (-not $valid.MatchesReceipt -or $valid.Status -cne "ready") {
    throw "valid supervisor task contract was rejected: $($valid.Detail)"
}
$disabled = New-TaskFixture
$disabled.State = "Disabled"
$disabledObservation =
    Get-LanForwarderSupervisorTaskContractObservation `
        -Task $disabled `
        -Supervisor $supervisor `
        -TaskInfo $validTaskInfo `
        -NowUtc $now
if (
    $disabledObservation.MatchesReceipt -or
    -not $disabledObservation.IdentityMatchesReceipt -or
    -not $disabledObservation.ScheduleMatchesReceipt -or
    $disabledObservation.OperationalStateReady
) {
    throw "disabled task did not fail only its operational-state contract"
}
foreach ($drift in @("settings-disabled", "trigger-disabled", "interval", "restart")) {
    $task = New-TaskFixture
    switch ($drift) {
        "settings-disabled" { $task.Settings.Enabled = $false }
        "trigger-disabled" { $task.Triggers[0].Enabled = $false }
        "interval" { $task.Triggers[0].Repetition.Interval = "PT5M" }
        "restart" { $task.Settings.RestartCount = 2 }
    }
    $observation =
        Get-LanForwarderSupervisorTaskContractObservation `
            -Task $task `
            -Supervisor $supervisor `
            -TaskInfo $validTaskInfo `
            -NowUtc $now
    if (
        $observation.MatchesReceipt -or
        -not $observation.IdentityMatchesReceipt -or
        $observation.ScheduleMatchesReceipt -or
        -not $observation.OperationalStateReady
    ) {
        throw "schedule drift '$drift' was not isolated correctly"
    }
}
$foreign = New-TaskFixture
$foreign.Actions[0].Execute = "C:\Windows\System32\cmd.exe"
$foreignObservation =
    Get-LanForwarderSupervisorTaskContractObservation `
        -Task $foreign `
        -Supervisor $supervisor `
        -TaskInfo $validTaskInfo `
        -NowUtc $now
if ($foreignObservation.IdentityMatchesReceipt) {
    throw "foreign task action was treated as receipt-owned"
}
$futureTask = New-TaskFixture
$futureTask.Triggers[0].StartBoundary = "2099-01-01T00:00:00Z"
$futureObservation =
    Get-LanForwarderSupervisorTaskContractObservation `
        -Task $futureTask `
        -Supervisor $supervisor `
        -TaskInfo $validTaskInfo `
        -NowUtc $now
if (
    $futureObservation.ScheduleMatchesReceipt -or
    -not $futureObservation.IdentityMatchesReceipt
) {
    throw "far-future trigger boundary was accepted"
}
$expiredSupervisor =
    $supervisor | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$expiredSupervisor.scheduleSealedAtUtc = "2000-01-01T00:00:00Z"
$expiredSupervisor.taskStartBoundaryUtc = "2000-01-01T00:00:15Z"
$expiredTask = New-TaskFixture
$expiredTask.Triggers[0].StartBoundary =
    $expiredSupervisor.taskStartBoundaryUtc
$expiredObservation =
    Get-LanForwarderSupervisorTaskContractObservation `
        -Task $expiredTask `
        -Supervisor $expiredSupervisor `
        -TaskInfo $validTaskInfo `
        -NowUtc $now
if (
    $expiredObservation.ScheduleMatchesReceipt -or
    -not $expiredObservation.IdentityMatchesReceipt
) {
    throw "expired repeating trigger window was accepted"
}
$missingInfoObservation =
    Get-LanForwarderSupervisorTaskContractObservation `
        -Task (New-TaskFixture) `
        -Supervisor $supervisor `
        -TaskInfo $null `
        -NowUtc $now
if (
    $missingInfoObservation.ScheduleMatchesReceipt -or
    -not $missingInfoObservation.IdentityMatchesReceipt
) {
    throw "missing scheduled-task runtime info was accepted"
}
foreach ($nextRunDrift in @(
    $now.AddMinutes(-10),
    $now.AddDays(1)
)) {
    $driftedTaskInfo = [PSCustomObject]@{
        NextRunTime = $nextRunDrift
    }
    $nextRunObservation =
        Get-LanForwarderSupervisorTaskContractObservation `
            -Task (New-TaskFixture) `
            -Supervisor $supervisor `
            -TaskInfo $driftedTaskInfo `
            -NowUtc $now
    if (
        $nextRunObservation.ScheduleMatchesReceipt -or
        -not $nextRunObservation.IdentityMatchesReceipt
    ) {
        throw "stale or far-future next run was accepted: $nextRunDrift"
    }
}
Write-Output "strict supervisor task contract runtime self-test passed"
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            test_script_path = (
                Path(temporary_directory)
                / "supervisor-task-contract-self-test.ps1"
            )
            test_script_path.write_text(
                function_sources + driver,
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    WINDOWS_POWERSHELL,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(test_script_path),
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
                "strict supervisor task contract runtime self-test passed",
                result.stdout,
            )

    def test_runbook_documents_source_free_start_and_port_preflight(self) -> None:
        runbook = (
            ROOT
            / "docs"
            / "10-infrastructure-and-deployment"
            / "local-release-qualification.md"
        ).read_text(encoding="utf-8")
        self.assertIn("-Action Start", runbook)
        self.assertIn("six candidate ports are unique and available", runbook)
        self.assertIn("does not require a clean", runbook)
        self.assertIn("source.archive.tar", runbook)
        self.assertIn("quiesces the current application before the final probe", runbook)
        self.assertIn("guest-compatible bridge release", runbook)
        self.assertIn(
            "this compatible current release is restarted even if it was stopped before Rollback",
            runbook,
        )
        self.assertIn("-BindAddress 192.168.1.25", runbook)
        self.assertIn("-AllowPublicNetworkProfile", runbook)
        self.assertIn("observed Windows interface/profile", runbook)
        self.assertIn("-LanTextOnly", runbook)
        self.assertIn("media was **not qualified**", runbook)
        self.assertIn("MinIO admin console (`5901`) stays", runbook)
        self.assertIn("Windows Firewall", runbook)
        self.assertIn("K_COMMS_PODMAN_BIND_ADDRESS=127.0.0.1", runbook)
        self.assertIn("all retained and referenced interpolation", runbook)
        self.assertIn("K_COMMS_PODMAN_BIND_ADDRESS=0.0.0.0", runbook)
        self.assertIn("cannot widen the retained publication", runbook)
        self.assertIn("scripts/lan_release_forwarder.mjs", runbook)
        self.assertIn("Forwarder: ready", runbook)
        self.assertIn("Forwarder: not-required", runbook)
        self.assertIn("schema v5", runbook)
        self.assertIn("http://<LAN-IP>", runbook)
        self.assertIn("always text-only", runbook)
        self.assertIn("local probes alone must not be reported as LAN", runbook)
        self.assertIn("HTTPS/WSS ingress", runbook)
        self.assertIn("reserving it in DHCP/router policy", runbook)
        self.assertIn("Windows Scheduled Task", runbook)
        self.assertIn("checks once per minute", runbook)
        self.assertIn("unexpectedly exited media-only forwarder", runbook)
        self.assertIn("-Action HealthCheck", runbook)
        self.assertIn("authentication, session, and join tokens", runbook)
        self.assertIn("Trusted HTTPS/WSS is mandatory", runbook)
        self.assertIn("internal-production use", runbook)
        self.assertIn("does **not** prove that", runbook)
        self.assertIn("the STUN probe failed", runbook)
        self.assertIn("never infer media capability from forwarder readiness", runbook)


if __name__ == "__main__":
    unittest.main()
