#!/usr/bin/env python3
"""Execute the real deployment script with isolated, synthetic host commands."""

from __future__ import annotations

import os
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = (
    str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")
    if os.name == "nt"
    else shutil.which("bash")
)
REVISION = "2" * 40
IMAGE = "ghcr.io/soyuz-tec/k-comms@sha256:" + "2" * 64

COMMON = r'''
K_COMMS_SOURCE=https://github.com/Soyuz-Tec/k-comms
K_COMMS_QUADLET_DIR="$SCRIPT_DIR/quadlet"
K_COMMS_RELEASE_ENV="$SCRIPT_DIR/release.env"
K_COMMS_RUNTIME_ENV="$SCRIPT_DIR/runtime.env"
K_COMMS_RECEIPT_DIR="$SCRIPT_DIR/receipts"
K_COMMS_TEMPLATE_DIR="$SCRIPT_DIR"
K_COMMS_MINIO_MC_IMAGE=fixture-minio
K_COMMS_CAPABILITIES=fixture-capabilities
log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
require_root() { :; }
require_command() { :; }
validate_environment() { :; }
validate_image_ref() { :; }
validate_revision() { :; }
assert_secure_runtime_env() { :; }
configured_environment() { echo production; }
acquire_deploy_lock() { :; }
assert_adopted_storage_ready_for_activation() { :; }
configured_bind_address() { echo 127.0.0.1; }
validate_ipv4() { :; }
current_app_image() { echo old-image; }
current_app_revision() { printf '%040d\n' 1; }
current_app_capabilities() { echo fixture-capabilities; }
classify_image_ref() { echo immutable-ghcr; }
configured_livekit_topology() { echo managed_cloud; }
unit_active() { [[ "$FAIL_AT" != first_install ]]; }
mktemp() { echo "$SCRIPT_DIR/guard"; }
write_release_env() { printf 'candidate\n' > "$3"; }
render_template() {
  [[ "$FAIL_AT" != render ]] || return 41
  printf 'candidate\n' > "$2"
}
podman() {
  printf 'podman %s\n' "$*" >> "$SCRIPT_DIR/calls"
  case "$*" in
    *org.opencontainers.image.source*) echo "$K_COMMS_SOURCE";;
    *org.opencontainers.image.revision*) printf '%040d\n' 2222 | tr 0 2;;
    *fixture-minio*) [[ "$FAIL_AT" != object ]] || return 42;;
    *CommsCore.Release.migrate*) [[ "$FAIL_AT" != migration ]] || return 43;;
    *assert_communication_rollback_compatible*) [[ "$FAIL_AT" != incompatible ]] || return 44;;
    *) :;;
  esac
}
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$SCRIPT_DIR/calls"
  case "$*" in
    'start k-comms-app.service')
      [[ "$FAIL_AT" != start ]] || return 45
      touch "$SCRIPT_DIR/running";;
    'stop k-comms-app.service') rm -f "$SCRIPT_DIR/running";;
    'enable --now k-comms-health.timer k-comms-backup.timer')
      [[ "$FAIL_AT" != timers ]] || return 46;;
  esac
  return 0
}
assert_postgres_volume_path() { :; }
assert_minio_volume_path() { :; }
wait_for_url() { :; }
jq() { printf '{"synthetic":true}\n'; }
'''

VERIFY = r'''#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$0")"
printf 'verify %s\n' "$*" >> "$root/calls"
if [[ "$*" == *--require-pwa* ]] &&
   [[ "$FAIL_AT" == health || "$FAIL_AT" == incompatible || "$FAIL_AT" == first_install ]]; then
  exit 47
fi
if [[ "$*" != *--require-pwa* && "$FAIL_AT" == recovery_health ]]; then
  exit 48
fi
'''


class DeployRecoveryTest(unittest.TestCase):
    def run_deployment(self, failure: str) -> tuple[subprocess.CompletedProcess, Path, list[str]]:
        self.assertTrue(BASH and Path(BASH).is_file(), "Bash is required for failure injection")
        temporary = tempfile.TemporaryDirectory(prefix="k-comms-deploy-recovery-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for directory in ("quadlet", "guard", "receipts"):
            (root / directory).mkdir()
        shutil.copyfile(ROOT / "deploy/proxmox/bin/deploy.sh", root / "deploy.sh")
        for name in ("runtime.env", "release.env", "quadlet/k-comms-app.container"):
            (root / name).write_text("previous\n", encoding="utf-8")
        (root / "common.sh").write_text(COMMON, encoding="utf-8", newline="\n")
        (root / "verify.sh").write_text(VERIFY, encoding="utf-8", newline="\n")
        (root / "backup.sh").write_text(
            '#!/usr/bin/env bash\n[[ "$FAIL_AT" != backup ]] || exit 33\n'
            'echo /synthetic/verified-backup\n', encoding="utf-8", newline="\n"
        )
        for name in ("deploy.sh", "backup.sh", "verify.sh"):
            (root / name).chmod(0o700)
        env = {**os.environ, "FAIL_AT": failure}
        # A failing backup exercises recovery verification without entering migration.
        if failure == "recovery_health":
            (root / "backup.sh").write_text("#!/usr/bin/env bash\nexit 33\n", newline="\n")
        result = subprocess.run(
            [BASH, str(root / "deploy.sh"), "--environment", "production", "--image", IMAGE,
             "--revision", REVISION], env=env, capture_output=True, text=True, timeout=20,
        )
        calls = (root / "calls").read_text(encoding="utf-8").splitlines()
        return result, root, calls

    def failure_record(self, root: Path) -> str:
        # If the durable evidence directory is unavailable, the guard must
        # remain in place (also exercised by Git Bash's restricted chmod).
        records = list(root.rglob("failure.txt"))
        self.assertEqual(len(records), 1)
        return records[0].read_text(encoding="utf-8")

    def test_backup_and_object_failure_restore_the_previous_application(self):
        for stage in ("backup", "object"):
            with self.subTest(stage=stage):
                result, root, calls = self.run_deployment(stage)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("systemctl start k-comms-app.service", calls)
                self.assertTrue((root / "running").exists())
                self.assertIn("recovery=previous_verified", self.failure_record(root))
                self.assertFalse(any("rollback_compatible" in call for call in calls))

    def test_failed_migration_stays_stopped_and_retains_evidence(self):
        result, root, calls = self.run_deployment("migration")
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertNotIn("systemctl start k-comms-app.service", calls)
        self.assertFalse((root / "running").exists())
        record = self.failure_record(root)
        self.assertIn("phase=migration", record)
        self.assertIn("recovery=stopped", record)

    def test_post_migration_errors_require_compatibility_before_restart(self):
        for stage in ("render", "health", "timers"):
            with self.subTest(stage=stage):
                result, root, calls = self.run_deployment(stage)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                check = next(i for i, call in enumerate(calls) if "rollback_compatible" in call)
                last_start = max(i for i, call in enumerate(calls) if call == "systemctl start k-comms-app.service")
                self.assertLess(check, last_start)
                self.assertIn("recovery=previous_verified", self.failure_record(root))
                self.assertTrue((root / "running").exists())
                self.assertFalse((root / "receipts/current.json").exists())

    def test_failed_compatibility_does_not_restart_previous_binary(self):
        result, root, calls = self.run_deployment("incompatible")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        check = next(i for i, call in enumerate(calls) if "rollback_compatible" in call)
        self.assertNotIn("systemctl start k-comms-app.service", calls[check:])
        self.assertFalse((root / "running").exists())
        self.assertIn("recovery=stopped", self.failure_record(root))

    def test_failed_previous_restart_or_health_is_not_reported_as_recovered(self):
        for stage in ("start", "recovery_health"):
            with self.subTest(stage=stage):
                result, root, _calls = self.run_deployment(stage)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse((root / "running").exists())
                self.assertIn("recovery=previous_recovery_failed", self.failure_record(root))

    def test_failed_first_install_is_stopped(self):
        result, root, _calls = self.run_deployment("first_install")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse((root / "running").exists())
        self.assertIn("recovery=stopped", self.failure_record(root))

    @unittest.skipIf(os.name == "nt", "Git Bash symlink creation depends on Windows developer mode")
    def test_success_cleans_guard_and_publishes_receipt(self):
        result, root, _calls = self.run_deployment("none")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((root / "receipts/current.json").is_symlink())
        self.assertFalse((root / "guard").exists())
        self.assertFalse((root / "receipts/failed-deployments").exists())


class StagingQualificationReuseTest(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "Qualification fixture requires Linux jq")
    def test_stale_invalid_or_future_qualification_runs_a_new_rehearsal(self):
        self.assertIsNotNone(shutil.which("jq"), "jq is required for qualification failure injection")
        for offset, reused in ((timedelta(hours=-1), True), (timedelta(days=-2), False),
                               (timedelta(minutes=10), False), (None, False)):
            with self.subTest(offset=offset), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "receipts").mkdir()
                shutil.copyfile(ROOT / "deploy/proxmox/bin/qualify-staging.sh", root / "qualify-staging.sh")
                qualified = ((datetime.now(timezone.utc) + offset).strftime("%Y-%m-%dT%H:%M:%SZ")
                             if offset is not None else "invalid")
                (root / "receipts/staging-qualification.json").write_text(json.dumps({
                    "image": IMAGE, "revision": REVISION, "qualified_at": qualified,
                }))
                (root / "common.sh").write_text(r'''
K_COMMS_RECEIPT_DIR="$SCRIPT_DIR/receipts"
require_root() { :; }
require_command() { :; }
validate_image_ref() { :; }
validate_revision() { :; }
configured_environment() { echo staging; }
current_app_image() { echo "$image"; }
current_app_revision() { echo "$revision"; }
log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
require_file() { log 'new rehearsal required'; exit 42; }
''', newline="\n")
                (root / "verify.sh").write_text("#!/usr/bin/env bash\nexit 0\n", newline="\n")
                (root / "verify.sh").chmod(0o700)
                result = subprocess.run(
                    [BASH, str(root / "qualify-staging.sh"), "--image", IMAGE, "--revision", REVISION],
                    capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(result.returncode, 0 if reused else 42, result.stderr)
                if not reused:
                    self.assertIn("new rehearsal required", result.stderr)


if __name__ == "__main__":
    unittest.main()
