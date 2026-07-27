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


if __name__ == "__main__":
    unittest.main()
