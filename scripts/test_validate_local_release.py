#!/usr/bin/env python3

from __future__ import annotations

import copy
import unittest

import yaml

from validate_local_release import (
    DEFAULT_COMPOSE,
    DEFAULT_RUNNER,
    ROOT,
    validate_local_release,
    validate_paths,
)


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

    def test_requires_instant_room_bootstrap_and_candidate_capability(self) -> None:
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
            "local release must bootstrap and verify the fixed instant-room tenant "
            "before candidate or restored-release capability checks",
            errors,
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
            "            -ExpectedLiveKitPort $LiveKitSignalPort `\n"
            "            -RequireGuestLinks",
            "            -ExpectedLiveKitPort $LiveKitSignalPort",
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
            "        -CandidateAppPort $AppPort `",
            "    Assert-RemovedCandidatePorts `\n"
            "        -CandidateAppPort $AppPort `",
        )
        runner = runner.replace("Group-Object -Property Port", "Group-Object -Property Name")
        runner = runner.replace(
            "Test-RetainedServiceOwnsPort", "RemovedRetainedPortOwnershipCheck"
        )
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "candidate port uniqueness and availability must be checked before image build",
            errors,
        )
        self.assertIn(
            "candidate port preflight must enforce uniqueness and loopback availability",
            errors,
        )
        self.assertIn(
            "candidate port preflight must only exempt verified port mappings owned by "
            "the retained release",
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


if __name__ == "__main__":
    unittest.main()
