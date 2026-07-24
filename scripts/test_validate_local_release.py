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
        ).replace("$current = $current.Parent", "$current = $null")
        errors = validate_local_release(self.compose, runner)
        self.assertIn(
            "custom state-root validation must inspect all existing ancestors", errors
        )
        self.assertIn(
            "custom state-root ancestor validation must walk to the filesystem root "
            "and reject reparse points",
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


if __name__ == "__main__":
    unittest.main()
