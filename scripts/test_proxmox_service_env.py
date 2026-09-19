#!/usr/bin/env python3
"""Secret isolation, fail-closed parsing, atomic publication and runtime checks."""
import importlib.util
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("service_env", ROOT / "deploy/proxmox/bin/service-env.py")
envs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(envs)


@unittest.skipIf(os.name == "nt", "Rootful Podman contract requires Linux ownership and symlinks")
class ServiceEnvironmentTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="kcomms-service-env-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "runtime.env"
        self.destination = self.root / "service-env"
        self.owner = os.geteuid()
        example = (ROOT / "deploy/proxmox/runtime.env.example").read_text()
        self.source.write_text(example.replace("CHANGE_ME", "synthetic-fixture"))
        self.source.chmod(0o600)

    def generate(self):
        envs.generate(self.source, self.destination, self.owner)

    def values(self):
        return envs.parse_source(self.source, self.owner)

    def test_exact_service_ownership_and_restricted_modes(self):
        self.generate()
        generation = envs.active_generation(self.destination, self.owner)
        self.assertEqual(generation.stat().st_mode & 0o777, 0o700)
        for service, allowed in envs.SERVICES.items():
            path = generation / f"{service}.env"
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            actual = {line.split("=", 1)[0] for line in path.read_text().splitlines()}
            self.assertEqual(actual, allowed & self.values().keys())
        self.assertNotIn("SECRET_KEY_BASE", (generation / "minio.env").read_text())
        self.assertNotIn("POSTGRES_PASSWORD", (generation / "app.env").read_text())
        self.assertNotIn("BOOTSTRAP_OWNER_PASSWORD", (generation / "app.env").read_text())
        envs.check(self.values(), self.destination, self.owner)

    def test_values_are_literal_not_evaluated(self):
        literal = "$(touch never-execute); # 'literal' = suffix"
        with self.source.open("a") as stream:
            stream.write("NOTIFICATION_PROVIDER_TOKEN=" + literal + "\n")
        self.generate()
        self.assertIn("NOTIFICATION_PROVIDER_TOKEN=" + literal + "\n",
                      (self.destination / "current/app.env").read_text())
        self.assertFalse((self.root / "never-execute").exists())

    def test_invalid_source_preserves_previous_generation_without_secret_output(self):
        self.generate()
        previous = os.readlink(self.destination / "current")
        original = self.source.read_text()
        for change in ("SECRET_KEY_BASE=do-not-log-value\n", "UNKNOWN_SECRET=do-not-log-value\n",
                       "export BAD=do-not-log-value\n", "NO_EQUALS\n",
                       "NOTIFICATION_PROVIDER_TOKEN=CHANGE_ME\n"):
            with self.subTest(change=change.split("=", 1)[0]):
                self.source.write_text(original + change)
                with self.assertRaises(envs.EnvironmentError) as error:
                    self.generate()
                self.assertNotIn("do-not-log-value", str(error.exception))
                self.assertEqual(os.readlink(self.destination / "current"), previous)
        self.source.write_text(original.replace("POSTGRES_PASSWORD=synthetic-fixture_HEX_32_BYTES", "POSTGRES_PASSWORD="))
        with self.assertRaises(envs.EnvironmentError):
            self.generate()

    def test_rejects_unsafe_source_permissions_owner_and_links(self):
        self.source.chmod(0o644)
        with self.assertRaises(envs.EnvironmentError):
            self.generate()
        self.source.chmod(0o600)
        with self.assertRaises(envs.EnvironmentError):
            envs.parse_source(self.source, self.owner + 1)
        original = self.root / "original.env"
        self.source.rename(original)
        self.source.symlink_to(original)
        with self.assertRaises(envs.EnvironmentError):
            self.generate()

    def test_rejects_writable_parent_and_linked_destination(self):
        self.root.chmod(0o777)
        with self.assertRaises(envs.EnvironmentError):
            self.generate()
        self.root.chmod(0o700)
        outside = self.root / "outside"
        outside.mkdir(mode=0o700)
        self.destination.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(envs.EnvironmentError):
            self.generate()

    def test_partial_write_failure_does_not_publish_or_leave_secret_fragments(self):
        self.generate()
        previous = os.readlink(self.destination / "current")
        with patch.object(envs.os, "replace", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                self.generate()
        self.assertEqual(os.readlink(self.destination / "current"), previous)
        self.assertEqual({path.name for path in self.destination.iterdir()}, {"current", previous})

    def test_rotation_is_atomic_and_removes_old_generation(self):
        self.generate()
        previous = envs.active_generation(self.destination, self.owner)
        self.source.write_text(self.source.read_text().replace("SECRET_KEY_BASE=synthetic-fixture_BASE64_64_BYTES",
                                                              "SECRET_KEY_BASE=rotated-fixture"))
        with self.assertRaises(envs.EnvironmentError):
            envs.check(self.values(), self.destination, self.owner)
        self.generate()
        self.assertFalse(previous.exists())
        self.assertIn("SECRET_KEY_BASE=rotated-fixture", (self.destination / "current/app.env").read_text())

    def test_detects_tampered_permissions_values_and_pointer(self):
        self.generate()
        path = self.destination / "current/minio.env"
        original = path.read_text()
        path.chmod(0o644)
        with self.assertRaises(envs.EnvironmentError):
            envs.check(self.values(), self.destination, self.owner)
        path.chmod(0o600)
        path.write_text(original + "SECRET_KEY_BASE=leak-fixture\n")
        with self.assertRaises(envs.EnvironmentError):
            envs.check(self.values(), self.destination, self.owner)
        (self.destination / "current").unlink()
        (self.destination / "current").symlink_to("../runtime.env")
        with self.assertRaises(envs.EnvironmentError):
            envs.check(self.values(), self.destination, self.owner)

    def test_container_inspection_rejects_cross_service_secrets_and_stale_values(self):
        values = self.values()
        for service in ("app", "postgres", "minio", "livekit"):
            current = dict(line.split("=", 1) for line in envs.contents(values, service).splitlines())
            if service == "app":
                current.update(K_COMMS_ROLE="all", K_COMMS_RUNTIME_PURPOSE="application",
                               K_COMMS_LOCAL_RELEASE="true", PORT="4000")
            current["PATH"] = "/usr/bin"
            entries = [f"{key}={value}" for key, value in current.items()]
            envs.check_container(values, service, entries)
            leaked = "POSTGRES_PASSWORD" if service == "app" else "SECRET_KEY_BASE"
            with self.assertRaises(envs.EnvironmentError):
                envs.check_container(values, service, entries + [f"{leaked}=leak-fixture"])
            with self.assertRaises(envs.EnvironmentError):
                envs.check_container(values, service, entries[1:])


class OwnershipContractTest(unittest.TestCase):
    def test_runtime_configuration_inputs_require_an_explicit_owner(self):
        runtime = (ROOT / "config/runtime.exs").read_text()
        keys = set(re.findall(r'System\.(?:get_env|fetch_env!)\("([A-Z][A-Z0-9_]*)"', runtime))
        self.assertEqual(keys - envs.APP_KEYS, {"HOSTNAME", "COMPUTERNAME"})
        self.assertTrue({"STUN_URLS", "TURN_URLS"} <= envs.APP_KEYS)
        self.assertFalse(envs.APP_KEYS & (envs.POSTGRES_KEYS | envs.MINIO_KEYS | envs.LIVEKIT_KEYS | envs.BOOTSTRAP_KEYS))


if __name__ == "__main__":
    unittest.main()
