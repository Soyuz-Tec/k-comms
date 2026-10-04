#!/usr/bin/env python3
"""Exercise real CI fixture scripts with isolated external-command failures."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class S3FixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="k-comms-ci-s3-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.state = self.root / "state"
        self.cache = self.root / "cache"
        self.env = {
            **os.environ,
            "PATH": str(self.commands) + os.pathsep + os.environ["PATH"],
            "K_COMMS_CI_S3_STATE_DIR": str(self.state),
            "K_COMMS_CI_S3_CACHE_DIR": str(self.cache),
            "K_COMMS_TEST_S3_HOST": "127.0.0.1",
            "K_COMMS_TEST_S3_PORT": "19000",
            "K_COMMS_TEST_S3_BUCKET": "k-comms-test",
            "K_COMMS_TEST_S3_ROOT_USER": "fixture-root",
            "K_COMMS_TEST_S3_ROOT_PASSWORD": "fixture-root-password",
            "K_COMMS_TEST_S3_ACCESS_KEY_ID": "fixture-app",
            "K_COMMS_TEST_S3_SECRET_ACCESS_KEY": "fixture-app-password",
            "K_COMMS_TEST_S3_KMS_SECRET_KEY": "fixture-key:fixture",
            "FIXTURE_TEST_ROOT": str(self.root),
        }

    def command(self, name: str, body: str) -> None:
        path = self.commands / name
        path.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
        path.chmod(0o700)

    def run_script(self, name: str, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(ROOT / "scripts" / name), *args], env=self.env,
            capture_output=True, text=True, timeout=15,
        )

    def docker(self, failure: str = "") -> None:
        self.env["FIXTURE_DOCKER_FAILURE"] = failure
        self.command("docker", r'''
printf '%s\n' "$*" >> "$FIXTURE_TEST_ROOT/docker-calls"
case "$1" in
  pull) [ "$FIXTURE_DOCKER_FAILURE" != pull ] || exit 125 ;;
  run)
    [ "$FIXTURE_DOCKER_FAILURE" != run ] || exit 125
    case "$*" in
      *--detach*)
        printf '%064d\n' 1
        ;;
    esac
    ;;
  inspect)
    if [ "$3" = '{{.State.Running}}' ]; then
      printf 'true\n'
    else
      printf '%064d ' 1
      cat "$K_COMMS_CI_S3_STATE_DIR/owner"
    fi
    ;;
  rm) : ;;
esac
''')

    def unavailable_then_ready(self) -> None:
        self.command("curl", r'''
if [ ! -f "$FIXTURE_TEST_ROOT/probed" ]; then
  touch "$FIXTURE_TEST_ROOT/probed"
  exit 7
fi
''')

    def test_pinned_images_remain_preferred_and_only_owned_container_is_removed(self) -> None:
        self.docker()
        self.unavailable_then_ready()
        result = self.run_script("ci_s3_fixture.sh", "start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ready (container)", result.stdout)
        calls = (self.root / "docker-calls").read_text()
        self.assertEqual(calls.count("pull quay.io/minio/"), 2)
        self.assertIn("@sha256:a1a8bd4ac40ad7881a245bab97323e18f971e4d4cba2c2007ec1bedd21cbaba2", calls)
        self.assertIn("@sha256:eb4ea9884b77704230e2423e9004d2fa738dc272876b9cc41a297d29443b8780", calls)
        self.assertIn("--publish 127.0.0.1:19000:9000", calls)
        self.assertIn("--pull never", calls)
        result = self.run_script("ci_s3_fixture.sh", "stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.state / "container").exists())
        calls = (self.root / "docker-calls").read_text()
        self.assertIn("rm --force " + "0" * 63 + "1", calls)

    def test_container_runtime_failure_does_not_enable_source_fallback(self) -> None:
        self.docker("run")
        self.unavailable_then_ready()
        result = self.run_script("ci_s3_fixture.sh", "start")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertNotIn("building checksum", result.stdout)
        self.assertFalse((self.state / "owner").exists())

    def test_pull_failure_enables_fallback_but_checksum_failure_is_fatal(self) -> None:
        self.docker("pull")
        self.unavailable_then_ready()
        archives = self.cache / "archives"
        archives.mkdir(parents=True)
        (archives / "go.tar.gz").write_bytes(b"untrusted-cache-content")
        result = self.run_script("ci_s3_fixture.sh", "start")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("building checksum-verified", result.stdout)
        self.assertIn("Checksum verification failed for cached go.tar.gz", result.stderr)
        self.assertFalse((self.state / "process").exists())
        self.assertFalse((self.state / "owner").exists())

    def test_existing_service_and_nonloopback_endpoint_are_never_adopted(self) -> None:
        self.docker()
        self.command("curl", "exit 0\n")
        result = self.run_script("ci_s3_fixture.sh", "start")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing service", result.stderr)
        self.assertFalse((self.root / "docker-calls").exists())
        self.env["K_COMMS_TEST_S3_HOST"] = "0.0.0.0"
        result = self.run_script("ci_s3_fixture.sh", "start")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("loopback", result.stderr)

    def test_stop_does_not_kill_an_unrelated_reused_pid(self) -> None:
        self.state.mkdir()
        # The parent test process is live, but neither its start time nor
        # executable matches the native MinIO ownership record.
        (self.state / "process").write_text(
            f"{os.getpid()} 1 /unrelated/minio\n", encoding="utf-8"
        )
        result = self.run_script("ci_s3_fixture.sh", "stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.state / "process").exists())

    def test_stop_cleans_up_the_owned_env_exec_transition(self) -> None:
        self.state.mkdir()
        process = subprocess.Popen(["bash", "-c", "exec -a env sleep 60"])
        self.addCleanup(lambda: process.poll() is not None or process.kill())
        proc = Path(f"/proc/{process.pid}")
        for _ in range(50):
            if (proc / "cmdline").read_bytes().split(b"\0", 1)[0] == b"env":
                break
            time.sleep(0.01)
        self.assertEqual((proc / "cmdline").read_bytes().split(b"\0", 1)[0], b"env")
        started = (proc / "stat").read_text().split()[21]
        (self.state / "process").write_text(
            f"{process.pid} {started} /fixture/bin/minio\n", encoding="utf-8"
        )
        (self.state / "owner").write_text("a" * 32 + "\n", encoding="utf-8")
        result = self.run_script("ci_s3_fixture.sh", "stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(process.wait(timeout=2), -15)

    def test_native_ownership_works_without_proc_exe_access(self) -> None:
        self.state.mkdir()
        self.command("readlink", "exit 1\n")
        binary = "/usr/bin/sleep"
        process = subprocess.Popen([binary, "60"])
        self.addCleanup(lambda: process.poll() is not None or process.kill())
        started = Path(f"/proc/{process.pid}/stat").read_text().split()[21]
        (self.state / "process").write_text(
            f"{process.pid} {started} {binary}\n", encoding="utf-8"
        )
        result = self.run_script("ci_s3_fixture.sh", "stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(process.wait(timeout=2), -15)

    def provision(self, failure: str = "") -> subprocess.CompletedProcess[str]:
        self.env.update({
            "FIXTURE_MC_FAILURE": failure,
            "S3_ENDPOINT": "http://127.0.0.1:19000",
            "S3_BUCKET": "k-comms-test",
            "MINIO_ROOT_USER": "fixture-root",
            "MINIO_ROOT_PASSWORD": "fixture-root-password",
            "S3_APP_ACCESS_KEY_ID": "fixture-app",
            "S3_APP_SECRET_ACCESS_KEY": "fixture-app-password",
        })
        self.command("mc", r'''
printf '%s\n' "$*" >> "$FIXTURE_TEST_ROOT/mc-calls"
case "$*" in
  'version info '*)
    [ "$FIXTURE_MC_FAILURE" != version ] || exit 0
    echo 'versioning is enabled' ;;
  'encrypt info '*)
    [ "$FIXTURE_MC_FAILURE" != encryption ] || exit 0
    echo 'sse-s3' ;;
  'admin policy create '*)
    [ "$FIXTURE_MC_FAILURE" != create ] || exit 41
    cp "$6" "$FIXTURE_TEST_ROOT/policy.json" ;;
  'admin policy attach '*)
    [ "$FIXTURE_MC_FAILURE" != attach ] || exit 42 ;;
  'admin policy entities '*) echo 'kcomms-app' ;;
esac
''')
        return self.run_script("provision_ci_s3_fixture.sh")

    def test_provision_preserves_versioning_encryption_and_bucket_scoped_app_policy(self) -> None:
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        policy = json.loads((self.root / "policy.json").read_text())
        self.assertEqual(
            [statement["Resource"] for statement in policy["Statement"]],
            [["arn:aws:s3:::k-comms-test"], ["arn:aws:s3:::k-comms-test/*"]],
        )
        self.assertTrue(all(statement["Effect"] == "Allow" for statement in policy["Statement"]))
        self.assertNotIn('"s3:*"', json.dumps(policy))
        calls = (self.root / "mc-calls").read_text()
        self.assertIn("admin policy attach local kcomms-app --user fixture-app", calls)
        self.assertNotIn("fixture-root-password", result.stdout)
        self.assertNotIn("fixture-app-password", result.stdout)

    def test_provisioning_configuration_and_policy_failures_remain_fatal(self) -> None:
        for failure in ("version", "encryption", "create", "attach"):
            with self.subTest(failure=failure):
                result = self.provision(failure)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
