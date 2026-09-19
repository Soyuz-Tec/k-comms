#!/usr/bin/env python3
"""Exercise monitoring decisions and real maintenance scripts with synthetic commands."""
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("operations", ROOT / "deploy/proxmox/bin/operations.py")
ops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ops)
NOW = 1_800_000_000


def stamp(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat()


def receipt_arguments(**changes):
    values = dict(kind="maintenance", status="success", started_at=stamp(NOW), started_ns=0,
                  duration=["backup=1000000000", "recovery=2000000000"], failed_phase=None,
                  backup_path="/synthetic/backup", was_active=True, health_restored=True,
                  writers_stopped=True,
                  outage_end_ns=3_000_000_000)
    return SimpleNamespace(**(values | changes))


class ReceiptTest(unittest.TestCase):
    def test_outage_ends_after_health_and_total_includes_finalization(self):
        receipt = ops.record(receipt_arguments(), stamp(NOW + 4), 4_000_000_000)
        self.assertEqual(receipt["duration_seconds"], 4)
        self.assertEqual(receipt["outage_observed_seconds"], 3)
        self.assertTrue(receipt["outage_interval_closed"])
        self.assertEqual(receipt["phases_seconds"], {"backup": 1, "recovery": 2})

    def test_failed_recovery_stays_open_and_retry_phase_durations_accumulate(self):
        receipt = ops.record(receipt_arguments(status="failed", health_restored=False,
            duration=["recovery=1000000000", "recovery=2000000000"]), stamp(NOW + 4), 4_000_000_000)
        self.assertFalse(receipt["outage_interval_closed"])
        self.assertEqual(receipt["outage_observed_seconds"], 4)
        self.assertEqual(receipt["phases_seconds"]["recovery"], 3)

    def test_inactive_application_has_no_new_outage_and_invalid_durations_fail(self):
        receipt = ops.record(receipt_arguments(was_active=False, health_restored=False), stamp(NOW + 4), 4_000_000_000)
        self.assertEqual(receipt["outage_observed_seconds"], 0)
        unknown = ops.record(receipt_arguments(writers_stopped=False), stamp(NOW + 4), 4_000_000_000)
        self.assertIsNone(unknown["outage_observed_seconds"])
        for duration in (["backup=-1"], ["backup=5000000000"], ["unexpected=1"]):
            with self.assertRaises(ValueError):
                ops.record(receipt_arguments(duration=duration), stamp(NOW + 4), 4_000_000_000)


@unittest.skipIf(os.name == "nt", "Host monitoring requires Linux permissions and statvfs")
class MonitorTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="kcomms-monitor-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.owner = os.geteuid()
        self.backup_root = self.root / "backups"
        self.backup_root.mkdir(mode=0o700)
        backup = self.backup_root / "synthetic-backup"
        backup.mkdir(mode=0o700)
        for name, value in (("COMPLETE", "k-comms-application-backup-v1\n"), ("SHA256SUMS", "synthetic-manifest\n")):
            path = backup / name
            path.write_text(value)
            path.chmod(0o600)
        self.backup_receipt = dict(schema="k-comms-operation-v1", kind="backup", status="success",
                                   finished_at=stamp(NOW - 100), backup_path=str(backup))
        ops.write_json(self.root / "backup-latest.json", self.backup_receipt)
        self.args = SimpleNamespace(config=self.root / "monitoring.json", state_dir=self.root / "monitoring",
            receipts=self.root, backup_root=self.backup_root, storage_path=[self.root], healthy=True)
        self.stats = SimpleNamespace(f_bavail=10_000_000, f_frsize=4096, f_files=1000, f_favail=900)
        self.delivery = Mock(return_value="succeeded")

    def monitor(self, now=NOW):
        return ops.monitor(self.args, now, self.owner, lambda _: self.stats, self.delivery)

    def test_default_is_local_only_and_writes_restricted_health_evidence(self):
        event = self.monitor()
        self.assertEqual(event["issues"], [])
        self.delivery.assert_not_called()
        self.assertEqual((self.args.state_dir / "monitor.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.args.state_dir.stat().st_mode & 0o777, 0o700)

    def test_stale_failed_incomplete_missing_and_foreign_backup_alert(self):
        for issue, change in (("backup_stale", {"finished_at": stamp(NOW - 200000)}),
                              ("backup_failed", {"status": "failed"}),
                              ("backup_evidence_invalid", {"backup_path": str(self.root)}),
                              ("backup_timestamp_invalid", {"finished_at": stamp(NOW + 600)})):
            ops.write_json(self.root / "backup-latest.json", self.backup_receipt | change)
            self.assertIn(issue, self.monitor()["issues"])
        ops.write_json(self.root / "backup-latest.json", self.backup_receipt)
        (Path(self.backup_receipt["backup_path"]) / "COMPLETE").write_text("wrong")
        self.assertIn("backup_incomplete", self.monitor()["issues"])
        (self.root / "backup-latest.json").unlink()
        self.assertIn("backup_missing", self.monitor()["issues"])

    def test_alert_change_dedup_recovery_and_deadman_are_explicit(self):
        ops.write_json(self.args.config, dict(alerts_enabled=True, deadman_enabled=True, hook_path="/etc/k-comms/hook"))
        self.assertEqual(self.monitor()["event"], "heartbeat")
        self.args.healthy = False
        self.assertEqual(self.monitor(NOW + 60)["event"], "alert")
        self.assertEqual(self.monitor(NOW + 120)["event"], "unchanged")
        self.assertEqual(self.delivery.call_count, 2)
        self.args.healthy = True
        self.assertEqual(self.monitor(NOW + 180)["event"], "recovery")
        self.assertEqual(self.delivery.call_count, 3)

    def test_failed_delivery_retries_and_stale_health_is_detected(self):
        ops.write_json(self.args.config, dict(alerts_enabled=True, hook_path="/etc/k-comms/hook"))
        self.monitor()
        self.args.healthy = False
        self.delivery.return_value = "failed"
        self.assertEqual(self.monitor(NOW + 60)["delivery"], "failed")
        self.monitor(NOW + 120)
        self.assertEqual(self.delivery.call_count, 2)
        self.assertIn("health_evidence_stale", self.monitor(NOW + 240)["issues"])

    def test_failed_recovery_delivery_retries_until_acknowledged(self):
        ops.write_json(self.args.config, dict(alerts_enabled=True, hook_path="/etc/k-comms/hook"))
        self.args.healthy = False
        self.assertEqual(self.monitor()["event"], "alert")
        self.args.healthy = True
        self.delivery.return_value = "timeout"
        self.assertEqual(self.monitor(NOW + 60)["event"], "recovery")
        self.delivery.return_value = "succeeded"
        self.assertEqual(self.monitor(NOW + 120)["event"], "recovery")
        self.assertEqual(self.monitor(NOW + 180)["event"], "heartbeat")
        self.assertEqual(self.delivery.call_count, 3)

    def test_enabling_alerts_delivers_existing_unacknowledged_issue_once(self):
        self.args.healthy = False
        self.monitor()
        self.monitor(NOW + 30)
        self.delivery.assert_not_called()
        ops.write_json(self.args.config, dict(alerts_enabled=True, hook_path="/etc/k-comms/hook"))
        self.assertEqual(self.monitor(NOW + 60)["event"], "alert")
        self.assertEqual(self.monitor(NOW + 120)["event"], "unchanged")
        self.monitor(NOW + 180)
        self.assertEqual(self.delivery.call_count, 1)

    def test_low_storage_and_failed_maintenance_are_visible(self):
        self.stats.f_bavail = 0
        self.stats.f_favail = 1
        ops.write_json(self.root / "maintenance-latest.json", dict(schema="k-comms-operation-v1", kind="maintenance", status="failed"))
        self.assertEqual(set(self.monitor()["issues"]), {"storage_0_bytes_low", "storage_0_inodes_low", "maintenance_failed"})

    def test_invalid_or_insecure_hook_configuration_fails_closed(self):
        for config in (dict(alerts_enabled=True), dict(backup_max_age_seconds=0), dict(unexpected=True)):
            ops.write_json(self.args.config, config)
            with self.assertRaises(ValueError):
                self.monitor()
        ops.write_json(self.args.config, {})
        self.args.config.chmod(0o644)
        with self.assertRaises(ValueError):
            self.monitor()
        self.delivery.assert_not_called()


class HookTest(unittest.TestCase):
    def test_hook_has_scrubbed_environment_bounded_timeout_and_no_output(self):
        def metadata(path):
            return SimpleNamespace(st_uid=0, st_mode=(stat.S_IFREG | 0o700) if path.name == "hook" else (stat.S_IFDIR | 0o755))
        runner = Mock(return_value=SimpleNamespace(returncode=0))
        with patch.object(Path, "lstat", metadata):
            self.assertEqual(ops.deliver({"hook_path": "/etc/k-comms/hook"}, {"event": "heartbeat"}, runner=runner), "succeeded")
            self.assertEqual(set(runner.call_args.kwargs["env"]), {"PATH", "LANG"})
            self.assertEqual(runner.call_args.kwargs["timeout"], 10)
            self.assertEqual(runner.call_args.kwargs["stdout"], subprocess.DEVNULL)
            runner.side_effect = subprocess.TimeoutExpired("hook", 10)
            self.assertEqual(ops.deliver({"hook_path": "/etc/k-comms/hook"}, {}, runner=runner), "timeout")
        with patch.object(Path, "lstat", return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o755)):
            with self.assertRaises(ValueError):
                ops.deliver({"hook_path": "/etc/k-comms/hook"}, {})


COMMON = r'''
K_COMMS_ENVIRONMENT_FILE="$SCRIPT_DIR/environment"
K_COMMS_RECEIPT_DIR="$SCRIPT_DIR/receipts"
K_COMMS_BACKUP_ROOT="$SCRIPT_DIR/backups"
K_COMMS_RUNTIME_ENV="$SCRIPT_DIR/runtime.env"
K_COMMS_RELEASE_ENV="$SCRIPT_DIR/release.env"
K_COMMS_QUADLET_DIR="$SCRIPT_DIR/quadlet"
require_root() { :; }
require_command() { :; }
acquire_deploy_lock() { :; }
log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
unit_active() {
  case "$1" in
    k-comms-app.service) [[ -f "$SCRIPT_DIR/app-running" ]];;
    k-comms-minio.service) [[ ! -f "$SCRIPT_DIR/minio-stopped" ]];;
    *) return 0;;
  esac
}
read_optional_env_value() { printf '%040d' 1; }
configured_bind_address() { echo 127.0.0.1; }
assert_minio_volume_path() { echo "$SCRIPT_DIR/minio"; }
wait_for_url() { :; }
systemctl() {
  printf '%s\n' "$*" >> "$SCRIPT_DIR/calls"
  case "$*" in
    'stop k-comms-app.service') [[ "$FAIL_AT" != stop ]] || return 41; rm -f "$SCRIPT_DIR/app-running";;
    'start k-comms-app.service') [[ "$FAIL_AT" != start ]] || return 42; touch "$SCRIPT_DIR/app-running";;
    'stop k-comms-minio.service') touch "$SCRIPT_DIR/minio-stopped";;
    'start k-comms-minio.service') rm -f "$SCRIPT_DIR/minio-stopped";;
  esac
}
podman() { [[ "$FAIL_AT" != dump ]] || return 43; echo synthetic-dump; }
pg_restore() { :; }
'''

FAKE_RECORDER = '''import json, pathlib, sys, time
if sys.argv[1] == "monotonic":
    print(time.monotonic_ns())
else:
    (pathlib.Path(__file__).parent / "record.json").write_text(json.dumps(sys.argv[2:]))
'''


@unittest.skipIf(os.name == "nt", "Real backup scripts use Linux permissions and Bash")
class MaintenanceScriptTest(unittest.TestCase):
    def fixture(self, script, failure="none", active=True):
        temporary = tempfile.TemporaryDirectory(prefix="kcomms-maintenance-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for directory in ("receipts", "backups", "quadlet", "minio"):
            (root / directory).mkdir()
        for filename in ("runtime.env", "release.env", "environment", "quadlet/k-comms-app.container", "minio/fixture"):
            (root / filename).write_text("synthetic\n")
        for filename in (script, "operations-common.sh"):
            shutil.copyfile(ROOT / "deploy/proxmox/bin" / filename, root / filename)
        (root / "common.sh").write_text(COMMON)
        (root / "operations.py").write_text(FAKE_RECORDER)
        if script == "quiesced-backup.sh":
            (root / "backup.sh").write_text('#!/usr/bin/env bash\nprintf "backup\\n" >> "$(dirname "$0")/calls"\n[[ "$FAIL_AT" != backup ]] || exit 33\necho /synthetic/backup\n')
        (root / "verify.sh").write_text('#!/usr/bin/env bash\nprintf "verify\\n" >> "$(dirname "$0")/calls"\nsleep 0.06\n[[ "$FAIL_AT" != health ]]\n')
        for path in root.glob("*.sh"):
            path.chmod(0o700)
        if active:
            (root / "app-running").touch()
        result = subprocess.run(["bash", str(root / script)], env=os.environ | {"FAIL_AT": failure},
                                capture_output=True, text=True, timeout=20)
        return result, root

    def record(self, root):
        arguments = json.loads((root / "record.json").read_text())
        def value(name):
            return arguments[len(arguments) - 1 - arguments[::-1].index(name) + 1]
        return arguments, value

    def test_maintenance_measures_through_verified_recovery(self):
        result, root = self.fixture("quiesced-backup.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        args, value = self.record(root)
        self.assertEqual(value("--status"), "success")
        self.assertIn("--health-restored", args)
        self.assertGreater(int(value("--outage-end-ns")) - int(value("--started-ns")), 60_000_000)
        self.assertEqual((root / "calls").read_text().splitlines(), ["stop k-comms-app.service", "backup", "start k-comms-app.service", "verify"])

    def test_backup_and_stop_failure_recover_but_remain_failed(self):
        for failure, code in (("backup", 33), ("stop", 41)):
            result, root = self.fixture("quiesced-backup.sh", failure)
            self.assertEqual(result.returncode, code, result.stderr)
            args, value = self.record(root)
            self.assertEqual(value("--status"), "failed")
            self.assertEqual(value("--failed-phase"), failure)
            self.assertIn("--health-restored", args)
            if failure == "stop":
                self.assertNotIn("--writers-stopped", args)

    def test_failed_restart_or_health_records_an_open_interval(self):
        for failure in ("start", "health"):
            result, root = self.fixture("quiesced-backup.sh", failure)
            self.assertNotEqual(result.returncode, 0)
            args, value = self.record(root)
            self.assertEqual(value("--status"), "failed")
            self.assertNotIn("--health-restored", args)
            self.assertIn("--was-active", args)

    def test_inactive_application_is_not_started_by_backup(self):
        result, root = self.fixture("quiesced-backup.sh", active=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        args, _ = self.record(root)
        self.assertNotIn("--was-active", args)
        self.assertEqual((root / "calls").read_text().strip(), "backup")

    def test_backup_records_all_phases_and_dump_failure(self):
        for failure in ("none", "dump"):
            result, root = self.fixture("backup.sh", failure, active=False)
            args, value = self.record(root)
            if failure == "none":
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(value("--status"), "success")
                phases = {args[index + 1].split("=")[0] for index, key in enumerate(args) if key == "--duration"}
                self.assertEqual(phases, {"postgres", "minio", "configuration", "manifest", "retention"})
                self.assertTrue((Path(result.stdout.strip()) / "COMPLETE").exists())
            else:
                self.assertEqual(result.returncode, 43, result.stderr)
                self.assertEqual(value("--status"), "failed")
                self.assertEqual(value("--failed-phase"), "postgres")
                self.assertFalse(any((root / "backups").glob("*/COMPLETE")))


if __name__ == "__main__":
    unittest.main()
