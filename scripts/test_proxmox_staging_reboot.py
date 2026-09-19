#!/usr/bin/env python3
"""Execute the real staging-only host helper with synthetic system commands."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "ghcr.io/soyuz-tec/k-comms@sha256:" + "a" * 64
REVISION = "b" * 40
REQUEST = "11111111-1111-1111-1111-111111111111"
BEFORE = "22222222-2222-2222-2222-222222222222"
AFTER = "33333333-3333-3333-3333-333333333333"
COMMON = r'''
K_COMMS_RECEIPT_DIR="$SCRIPT_DIR/receipts"
require_root() { :; }
require_command() { :; }
validate_image_ref() { :; }
validate_revision() { :; }
configured_environment() { echo "$HOST_ENV"; }
configured_bind_address() { echo "$HOST_BIND"; }
acquire_deploy_lock() { :; }
current_app_image() { echo "$EXPECTED_IMAGE"; }
current_app_revision() { echo "$EXPECTED_REVISION"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
cat() {
  if [[ "$1" == /proc/sys/kernel/random/boot_id ]]; then echo "$BOOT_ID"; else command cat "$@"; fi
}
stat() { echo 600:0; }
systemd-run() {
  printf 'schedule %s\n' "$*" >> "$SCRIPT_DIR/calls"
  [[ "$FAIL_AT" != schedule ]]
}
systemctl() {
  printf '%s\n' "$*" >> "$SCRIPT_DIR/calls"
  [[ "$FAIL_AT" != timers ]]
}
assert_running_service_environments() { [[ "$FAIL_AT" != service_env ]]; }
'''


@unittest.skipIf(os.name == "nt", "Staging host helper requires Linux jq and symlinks")
class StagingRebootTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(shutil.which("jq"), "jq is required for host command regressions")
        temporary = tempfile.TemporaryDirectory(prefix="kcomms-staging-reboot-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "receipts").mkdir()
        shutil.copyfile(ROOT / "deploy/proxmox/bin/qualify-staging-reboot.sh", self.root / "qualify-staging-reboot.sh")
        (self.root / "common.sh").write_text(COMMON)
        (self.root / "verify.sh").write_text('#!/usr/bin/env bash\n[[ "$FAIL_AT" != health ]]\n')
        (self.root / "verify.sh").chmod(0o700)
        self.env = dict(os.environ, HOST_ENV="staging", HOST_BIND="192.168.1.23", BOOT_ID=BEFORE,
                        EXPECTED_IMAGE=IMAGE, EXPECTED_REVISION=REVISION, FAIL_AT="none")
        self.qualification = dict(schema="k-comms-staging-qualification-receipt-v1", environment="staging",
                                  image=IMAGE, revision=REVISION,
                                  qualified_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.write_qualification()

    def write_qualification(self):
        (self.root / "receipts/staging-qualification.json").write_text(json.dumps(self.qualification))

    def run_helper(self, action, previous=BEFORE):
        return subprocess.run(["bash", str(self.root / "qualify-staging-reboot.sh"), "--action", action,
            "--request-id", REQUEST, "--image", IMAGE, "--revision", REVISION, "--previous-boot-id", previous],
            env=self.env, capture_output=True, text=True, timeout=20)

    def test_success_requires_new_boot_health_timers_and_environment_inspection(self):
        request = self.run_helper("request")
        self.assertEqual(request.returncode, 0, request.stderr)
        self.assertEqual(request.stdout.strip(), BEFORE)
        self.assertNotEqual(self.run_helper("verify").returncode, 0)
        self.env["BOOT_ID"] = AFTER
        result = self.run_helper("verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((self.root / "receipts/staging-reboot.json").read_text())
        self.assertEqual(receipt["boot_id"], AFTER)
        self.assertEqual(receipt["previous_boot_id"], BEFORE)
        self.assertTrue(receipt["readiness_verified"] and receipt["timers_verified"] and receipt["service_environments_verified"])
        self.assertEqual((self.root / f"receipts/staging-reboot-{REQUEST}.json").stat().st_mode & 0o777, 0o600)
        calls = (self.root / "calls").read_text()
        self.assertIn(f"schedule --quiet --unit=k-comms-staging-reboot-{REQUEST} --on-active=5s --timer-property=AccuracySec=1s /usr/bin/systemctl reboot", calls)
        self.assertIn("is-enabled --quiet k-comms-backup.timer", calls)
        self.assertIn("is-active --quiet k-comms-health.timer", calls)

    def test_production_wrong_bind_and_changed_release_never_schedule_reboot(self):
        for name, bad in (("HOST_ENV", "production"), ("HOST_BIND", "127.0.0.1"),
                          ("EXPECTED_IMAGE", IMAGE + "wrong"), ("EXPECTED_REVISION", "c" * 40)):
            original = self.env[name]
            self.env[name] = bad
            self.assertNotEqual(self.run_helper("request").returncode, 0)
            self.assertFalse((self.root / "calls").exists())
            self.env[name] = original

    def test_reboot_permission_denied_or_old_qualification_fails_closed(self):
        self.env["FAIL_AT"] = "schedule"
        self.assertNotEqual(self.run_helper("request").returncode, 0)
        self.assertFalse((self.root / "receipts/staging-reboot.json").exists())
        (self.root / f"receipts/staging-reboot-request-{REQUEST}.json").unlink()
        self.env["FAIL_AT"] = "none"
        self.qualification["qualified_at"] = (datetime.now(timezone.utc) - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.write_qualification()
        self.assertNotEqual(self.run_helper("request").returncode, 0)
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), 1)

    def test_wrong_request_or_failed_recovery_never_publishes_receipt(self):
        self.assertEqual(self.run_helper("request").returncode, 0)
        self.env["BOOT_ID"] = AFTER
        self.assertNotEqual(self.run_helper("verify", previous=REQUEST).returncode, 0)
        for failure in ("health", "timers", "service_env"):
            self.env["FAIL_AT"] = failure
            self.assertNotEqual(self.run_helper("verify").returncode, 0)
            self.assertFalse((self.root / "receipts/staging-reboot.json").exists())


if __name__ == "__main__":
    unittest.main()
