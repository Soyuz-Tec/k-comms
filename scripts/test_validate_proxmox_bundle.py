#!/usr/bin/env python3

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from validate_proxmox_bundle import REQUIRED_FILES, validate


REPO_ROOT = Path(__file__).resolve().parents[1]


class ProxmoxBundleValidatorTest(unittest.TestCase):
    def test_repository_bundle_passes(self) -> None:
        self.assertEqual(validate(REPO_ROOT), [])

    def test_rejects_weakened_post_development_completion_standard(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = (
            root
            / "docs/14-operations/development-to-production-completion-standard.md"
        )
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "Same immutable digest qualified in staging and production",
                "Independently rebuilt images may be used",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("completion standard is missing control" in error for error in errors)
        )

    def test_rejects_noncanonical_windows_development_workspace(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = (
            root
            / "docs/10-infrastructure-and-deployment/environments/development.md"
        )
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                r"C:\Users\vasan\OneDrive\Documents\k-comms",
                r"C:\Users\vasan\OneDrive\Documents\k-comms 2",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any(
                "development environment standard is missing control" in error
                for error in errors
            )
        )

    def copied_contract(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for relative in REQUIRED_FILES:
            source = REPO_ROOT / relative
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        return temporary, root

    def test_rejects_mutable_application_image(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/quadlet/k-comms-app.container.in"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "Image=@@IMAGE_REF@@", "Image=ghcr.io/soyuz-tec/k-comms:latest"
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any("mutable latest tag" in error for error in errors))

    def test_rejects_populated_secret_example(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/runtime.env.example"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "POSTGRES_PASSWORD=CHANGE_ME_HEX_32_BYTES",
                "POSTGRES_PASSWORD=test-only-populated-value",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertIn(
            "runtime.env.example must leave POSTGRES_PASSWORD as a placeholder",
            errors,
        )

    def test_rejects_missing_protected_environment_gate(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/deploy-proxmox.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "      name: ${{ inputs.environment }}",
                "      name: unprotected",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("name: ${{ inputs.environment }}" in error for error in errors)
        )

    def test_rejects_missing_livekit_cloud_environment_secret(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/deploy-proxmox.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "secrets.K_COMMS_LIVEKIT_CLOUD_CREDENTIAL",
                "secrets.REMOVED_LIVEKIT_CREDENTIAL",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any(
                "secrets.K_COMMS_LIVEKIT_CLOUD_CREDENTIAL" in error
                for error in errors
            )
        )

    def test_rejects_os_pinned_deployment_runner(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/deploy-proxmox.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "runs-on: [self-hosted, x64, k-comms-deploy]",
                "runs-on: [self-hosted, windows, x64, k-comms-deploy]",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any(
                "runs-on: [self-hosted, x64, k-comms-deploy]" in error
                for error in errors
            )
        )

    def test_rejects_missing_linux_secret_file_mode(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/deploy-proxmox.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "& chmod 0600 -- $path",
                "Write-Host 'Linux file protection removed'",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any("chmod 0600 -- $path" in error for error in errors))

    def test_rejects_platform_specific_native_command_resolution(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "scripts/proxmox/native-command.ps1"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                '"$Name.exe"',
                '"$Name.cmd"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any('"$Name.exe"' in error for error in errors))

    def test_rejects_ambiguous_native_command_resolution(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "scripts/proxmox/native-command.ps1"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "Select-Object -First 1",
                "Select-Object",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any("Select-Object -First 1" in error for error in errors))

    def test_rejects_nonreusable_protected_deployment_workflow(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/deploy-proxmox.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "  workflow_call:\n",
                "  workflow_call_removed:\n",
                1,
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any("workflow_call:" in error for error in errors))

    def test_rejects_production_that_does_not_need_staging(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/container.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "    needs: [publish, staging]\n",
                "    needs: publish\n",
                1,
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("needs: [publish, staging]" in error for error in errors)
        )

    def test_rejects_cancelling_an_in_progress_main_release(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/container.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
                "cancel-in-progress: true",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("cancel-in-progress:" in error for error in errors)
        )

    def test_rejects_missing_isolated_restore_rehearsal(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/restore-rehearsal.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "k-comms-restore-rehearsal-receipt-v1",
                "restore-complete",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("restore-rehearsal.sh is missing control" in error for error in errors)
        )

    def test_rejects_restore_rehearsal_that_contaminates_receipt_stdout(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/restore-rehearsal.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "sha256sum --check --strict SHA256SUMS) >&2",
                "sha256sum --check --strict SHA256SUMS)",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("restore-rehearsal.sh is missing control" in error for error in errors)
        )

    def test_rejects_missing_livekit_runtime_rollback(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/deploy.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'install -m 0600 "${rollback_dir}/runtime.env" "$K_COMMS_RUNTIME_ENV"',
                ": # removed protected runtime rollback",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("deploy.sh is missing control" in error for error in errors)
        )

    def test_rejects_removed_release_gate_before_or_after_approval(self) -> None:
        for occurrence in (0, 1):
            with self.subTest(occurrence=occurrence):
                temporary, root = self.copied_contract()
                self.addCleanup(temporary.cleanup)
                path = root / ".github/workflows/deploy-proxmox.yml"
                command = "python scripts/verify_release_gates.py"
                parts = path.read_text(encoding="utf-8").split(command)
                parts[occurrence] += "echo gate removed"
                document = command.join(parts[:occurrence + 1]) + command.join(parts[occurrence + 1:])
                path.write_text(document, encoding="utf-8")
                self.assertTrue(any("release gates must run" in error for error in validate(root)))

    def test_rejects_staging_artifact_without_attempt_binding(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/deploy-proxmox.yml"
        path.write_text(path.read_text(encoding="utf-8").replace(
            "-attempt-${{ github.run_attempt }}", ""), encoding="utf-8")
        self.assertTrue(any("release evidence workflow is missing" in error for error in validate(root)))

    def test_rejects_direct_manual_production_option(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/deploy-proxmox.yml"
        path.write_text(path.read_text(encoding="utf-8").replace(
            "          - staging", "          - staging\n          - production"), encoding="utf-8")
        self.assertIn("manual production must use the complete Container release chain", validate(root))

    def test_rejects_missing_recovery_or_ci_failure_injection(self) -> None:
        for script in ("test_verify_release_gates.py", "test_proxmox_deploy_recovery.py"):
            with self.subTest(script=script):
                temporary, root = self.copied_contract()
                self.addCleanup(temporary.cleanup)
                path = root / ".github/workflows/ci.yml"
                path.write_text(path.read_text(encoding="utf-8").replace(
                    f"python scripts/{script}", "echo removed"), encoding="utf-8")
                self.assertTrue(any("CI must execute release safety" in error for error in validate(root)))

    def test_rejects_unencoded_remote_shell(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "scripts/proxmox/deploy-remote.ps1"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "base64 -d | bash",
                "bash -lc",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any("base64 -d | bash" in error for error in errors))

    def test_rejects_fixed_production_volume_identity(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/quadlet/k-comms-postgres-data.volume.in"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "VolumeName=@@POSTGRES_VOLUME@@",
                "VolumeName=k-comms-postgres-data",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any("configurable volume identity" in error for error in errors))

    def test_rejects_missing_adoption_fallback(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "adoption failed; restoring the retained legacy service",
                "adoption failed",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("legacy production adoption is missing control" in error for error in errors)
        )

    def test_rejects_legacy_container_auto_restart_after_adoption(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'podman update --restart=no "$container"',
                'podman update --restart=unless-stopped "$container"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("legacy production adoption is missing control" in error for error in errors)
        )

    def test_rejects_missing_legacy_restart_policy_fallback(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'podman update --restart="$original_restart_policy" "$container"',
                'podman update --restart=no "$container"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("legacy production adoption is missing control" in error for error in errors)
        )

    def test_rejects_enabled_legacy_auxiliary_boot_trigger(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'systemctl disable --now "${legacy_auxiliary_units[@]}"',
                'systemctl stop "${legacy_auxiliary_units[@]}"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("legacy production adoption is missing control" in error for error in errors)
        )

    def test_rejects_missing_legacy_auxiliary_fallback(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'systemctl enable --now "${legacy_auxiliary_units[@]}"',
                'systemctl start "${legacy_auxiliary_units[@]}"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("legacy production adoption is missing control" in error for error in errors)
        )

    def test_rejects_missing_livekit_udp_host_tuning(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/sysctl/99-k-comms-livekit.conf"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "net.core.rmem_max = 5000000",
                "net.core.rmem_max = 425984",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertIn("LiveKit UDP receive-buffer tuning is missing", errors)

    def test_rejects_unsynchronized_livekit_udp_host_tuning(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/sync-assets.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "sysctl --load /etc/sysctl.d/99-k-comms-livekit.conf >/dev/null",
                ":",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("sync-assets.sh is missing LiveKit host tuning" in error for error in errors)
        )

    def test_rejects_fixed_podman_network_subnet(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/quadlet/k-comms.network.in"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "Subnet=@@PODMAN_SUBNET@@",
                "Subnet=10.89.0.0/24",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(any("configurable network identity" in error for error in errors))

    def test_rejects_direct_execution_of_transferred_installer(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'bash "${SCRIPT_DIR}/install.sh"',
                '"${SCRIPT_DIR}/install.sh"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("legacy production adoption is missing control" in error for error in errors)
        )

    def test_rejects_missing_csp_normalization(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'normalize_runtime_csp "$K_COMMS_RUNTIME_ENV"',
                ":",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("legacy production adoption is missing control" in error for error in errors)
        )

    def test_rejects_unscoped_adopted_image_verification(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/verify.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "an adopted local image is accepted only in production",
                "adopted image accepted",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("verify.sh is missing adopted-image control" in error for error in errors)
        )

    def test_rejects_runtime_image_without_pwa_capability_label(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "Dockerfile"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                '      io.k-comms.pwa="1"',
                '      io.k-comms.pwa="0"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertIn("Dockerfile runtime image is missing io.k-comms.pwa=1", errors)

    def test_rejects_verifier_without_required_pwa_gate(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/verify.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "--require-pwa) require_pwa=true; shift ;;",
                "--pwa-optional) require_pwa=false; shift ;;",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("verify.sh is missing PWA control" in error for error in errors)
        )

    def test_rejects_unrevisioned_worker_deployment_probe(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/verify.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'worker_url="${pwa_origin}/k-comms-sw.js?revision=${release_revision}"',
                'worker_url="${pwa_origin}/k-comms-sw.js"',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("verify.sh is missing PWA control" in error for error in errors)
        )

    def test_rejects_unrevisioned_public_worker_probe(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / ".github/workflows/container.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "https://comms.avayaworks.com/app/k-comms-sw.js?revision=${REVISION}",
                "https://comms.avayaworks.com/app/k-comms-sw.js",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any(
                "automatic release workflow is missing control" in error
                for error in errors
            )
        )

    def test_rejects_missing_hashed_asset_negative_probe(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/verify.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "PWA missing hash-shaped asset did not return HTTP 404",
                "missing asset ignored",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("verify.sh is missing PWA control" in error for error in errors)
        )

    def test_rejects_candidate_deploy_without_required_pwa_verification(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/deploy.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                '"${SCRIPT_DIR}/verify.sh" --environment "$environment" --require-pwa',
                '"${SCRIPT_DIR}/verify.sh" --environment "$environment" --skip-host-tuning',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any(
                "deploy.sh is missing control:" in error and "--require-pwa" in error
                for error in errors
            )
        )

    def test_rejects_incomplete_staging_pwa_qualification(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/qualify-staging.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                '"${SCRIPT_DIR}/verify.sh" --environment staging --require-pwa',
                '"${SCRIPT_DIR}/verify.sh" --environment staging',
                1,
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any(
                "qualify-staging.sh must require PWA verification" in error
                for error in errors
            )
        )

    def test_rejects_rollback_that_requires_pwa_capability(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/rollback.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                '"${SCRIPT_DIR}/verify.sh" --environment "$environment"',
                '"${SCRIPT_DIR}/verify.sh" --environment "$environment" --require-pwa',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertIn(
            "rollback.sh must permit feature-aware verification of a pre-PWA image",
            errors,
        )

    def test_rejects_legacy_adoption_that_requires_pwa_capability(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'bash "${SCRIPT_DIR}/verify.sh" --environment production',
                'bash "${SCRIPT_DIR}/verify.sh" --environment production --require-pwa',
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertIn(
            "legacy production adoption must permit verification of a pre-PWA image",
            errors,
        )

    def test_rejects_missing_tunnel_recovery(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/adopt-legacy-production.sh"
        document = path.read_text(encoding="utf-8")
        path.write_text(
            document.replace(
                "    start_tunnel_if_installed || true\n",
                "",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertTrue(
            any("start the tunnel after activation and fallback" in error for error in errors)
        )

    def test_rejects_tunnel_app_lifecycle_coupling(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/systemd/cloudflared-kcomms.service"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "After=network-online.target",
                "After=network-online.target k-comms-app.service\n"
                "Requires=k-comms-app.service",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertIn(
            "Cloudflare connector must remain lifecycle-independent from the app",
            errors,
        )

    def test_rejects_unsynchronized_tunnel_unit(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/sync-assets.sh"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                'install -m 0644 "${BUNDLE_DIR}/systemd/cloudflared-kcomms.service" \\\n'
                "  /etc/systemd/system/\n",
                "",
            ),
            encoding="utf-8",
        )
        errors = validate(root)
        self.assertIn(
            "deploy/proxmox/bin/sync-assets.sh must install the Cloudflare connector unit",
            errors,
        )


    def test_rejects_shared_runtime_environment_in_sidecar(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/quadlet/k-comms-minio.container.in"
        path.write_text(path.read_text().replace(
            "EnvironmentFile=/etc/k-comms/service-env/current/minio.env",
            "EnvironmentFile=/etc/k-comms/runtime.env"))
        self.assertTrue(any("shared host environment is forbidden" in error for error in validate(root)))

    def test_rejects_shared_runtime_environment_in_one_shot(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/deploy.sh"
        path.write_text(path.read_text().replace(
            '--env-file "${K_COMMS_SERVICE_ENV}/object-admin.env"',
            '--env-file "$K_COMMS_RUNTIME_ENV"'))
        self.assertTrue(any("one-shot container exposes" in error for error in validate(root)))

    def test_rejects_missing_restore_environment_regeneration(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/restore.sh"
        path.write_text(path.read_text().replace("generate_service_envs", ":"))
        self.assertIn("restore.sh must regenerate restricted service environments", validate(root))


    def test_rejects_missing_operational_evidence(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/bin/quiesced-backup.sh"
        path.write_text(path.read_text().replace("operation_record", "discard_record"))
        self.assertIn("quiesced-backup.sh must retain operation duration and failure evidence", validate(root))

    def test_rejects_default_external_monitoring_delivery(self) -> None:
        temporary, root = self.copied_contract()
        self.addCleanup(temporary.cleanup)
        path = root / "deploy/proxmox/monitoring.json.example"
        path.write_text(path.read_text().replace('"alerts_enabled": false', '"alerts_enabled": true'))
        self.assertIn("external monitoring delivery must remain disabled by default", validate(root))


if __name__ == "__main__":
    unittest.main()
