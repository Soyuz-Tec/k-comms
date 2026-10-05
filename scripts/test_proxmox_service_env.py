#!/usr/bin/env python3
"""Secret isolation, fail-closed parsing, atomic publication and runtime checks."""
import importlib.util
import base64
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

    def test_history_cursor_key_reaches_only_application_replicas(self):
        synthetic_key = "synthetic-history-cursor-key-dedicated-32-bytes"
        self.source.write_text(self.source.read_text().replace(
            "GOV_HISTORY_CURSOR_KEY=", "GOV_HISTORY_CURSOR_KEY=" + synthetic_key))
        self.generate()
        self.assertIn("GOV_HISTORY_CURSOR_KEY=" + synthetic_key + "\n",
                      (self.destination / "current/app.env").read_text())
        for service in ("postgres", "minio", "livekit", "object-admin", "bootstrap"):
            self.assertNotIn("GOV_HISTORY_CURSOR_KEY",
                             (self.destination / "current" / f"{service}.env").read_text())
        envs.check(self.values(), self.destination, self.owner)

    def test_matrix_credentials_project_only_to_application_without_secret_diagnostics(self):
        original = self.source.read_text()
        controls = {
            "PRIVATE_ROOMS_ENABLED": "false",
            "MATRIX_CLIENT_PROVISIONING_ENABLED": "false",
            "MATRIX_CONTROL_USER_ID": "@control:matrix.example.test",
            "MATRIX_SERVER_NAME": "matrix.example.test",
            "MATRIX_HOMESERVER_URL": "https://matrix.example.test",
        }
        credentials = {
            "MATRIX_IDENTITY_ADMIN_TOKEN": "synthetic-identity-token-not-for-logging",
            "MATRIX_CONTROL_ADMIN_TOKEN": "synthetic-control-token-not-for-logging",
        }
        credential_files = {}
        for key, value in credentials.items():
            path = self.root / (key.lower() + ".secret")
            path.write_text(value)
            path.chmod(0o600)
            credential_files[key + "_FILE"] = str(path)
        all_credentials = credentials | credential_files
        for mode, selected in (("inline", credentials), ("file", credential_files)):
            with self.subTest(mode=mode):
                inputs = controls | selected
                self.source.write_text(original + "\n" + "".join(
                    f"{key}={value}\n" for key, value in inputs.items()))
                self.generate()
                values = self.values()
                generation = envs.active_generation(self.destination, self.owner)
                application_path = generation / "app.env"
                application = dict(line.split("=", 1)
                                   for line in application_path.read_text().splitlines())
                self.assertEqual(generation.stat().st_mode & 0o777, 0o700)
                self.assertEqual(application_path.stat().st_mode & 0o777, 0o600)
                for key, value in inputs.items():
                    self.assertEqual(application[key], value)
                self.assertFalse((all_credentials.keys() - selected.keys()) & application.keys())
                envs.check(values, self.destination, self.owner)
                launch = application | {
                    "K_COMMS_ROLE": "all", "K_COMMS_RUNTIME_PURPOSE": "application",
                    "K_COMMS_LOCAL_RELEASE": "true", "PORT": "4000",
                }
                envs.check_container(values, "app", [f"{key}={value}"
                                                       for key, value in launch.items()])

                for service in ("postgres", "minio", "livekit", "object-admin", "bootstrap"):
                    path = generation / f"{service}.env"
                    restricted = path.read_text()
                    for key in controls.keys() | all_credentials.keys():
                        self.assertNotIn(key, restricted)
                    for value in all_credentials.values():
                        self.assertNotIn(value, restricted)
                    entries = restricted.splitlines()
                    if service in ("postgres", "minio", "livekit"):
                        envs.check_container(values, service, entries)
                    for key, value in all_credentials.items():
                        with self.subTest(service=service, credential=key):
                            # File checks cover every service, including one-shot jobs.
                            path.write_text(restricted + f"{key}={value}\n")
                            try:
                                with self.assertRaises(envs.EnvironmentError) as error:
                                    envs.check(values, self.destination, self.owner)
                                for secret in all_credentials.values():
                                    self.assertNotIn(secret, str(error.exception))
                            finally:
                                path.write_text(restricted)
                            if service in ("postgres", "minio", "livekit"):
                                with self.assertRaises(envs.EnvironmentError) as error:
                                    envs.check_container(values, service, entries + [f"{key}={value}"])
                                for secret in all_credentials.values():
                                    self.assertNotIn(secret, str(error.exception))
                envs.check(values, self.destination, self.owner)
                previous = os.readlink(self.destination / "current")
                with self.source.open("a") as stream:
                    stream.write("MATRIX_UNDECLARED_TOKEN=" + credentials["MATRIX_IDENTITY_ADMIN_TOKEN"] + "\n")
                with self.assertRaises(envs.EnvironmentError) as error:
                    self.generate()
                for secret in all_credentials.values():
                    self.assertNotIn(secret, str(error.exception))
                self.assertEqual(os.readlink(self.destination / "current"), previous)

    def test_short_history_cursor_key_refuses_rotation_without_secret_output(self):
        self.generate()
        previous = os.readlink(self.destination / "current")
        self.source.write_text(self.source.read_text().replace(
            "GOV_HISTORY_CURSOR_KEY=", "GOV_HISTORY_CURSOR_KEY=private-short-key"))
        with self.assertRaises(envs.EnvironmentError) as error:
            self.generate()
        self.assertIn("GOV_HISTORY_CURSOR_KEY", str(error.exception))
        self.assertNotIn("private-short-key", str(error.exception))
        self.assertEqual(os.readlink(self.destination / "current"), previous)

    def test_history_cursor_rejects_recovery_secret_without_publishing_or_logging(self):
        self.generate()
        previous = os.readlink(self.destination / "current")
        recovery_key = self.values()["PASSWORD_RECOVERY_SIGNING_KEY"]
        self.source.write_text(self.source.read_text().replace(
            "GOV_HISTORY_CURSOR_KEY=", "GOV_HISTORY_CURSOR_KEY=" + recovery_key))
        with self.assertRaises(envs.EnvironmentError) as error:
            self.generate()
        self.assertIn("dedicated", str(error.exception))
        self.assertNotIn(recovery_key, str(error.exception))
        self.assertEqual(os.readlink(self.destination / "current"), previous)

    def test_history_cursor_rejects_reencoded_rotated_encryption_key(self):
        synthetic_key = "g" * 32
        encoded = base64.b64encode(synthetic_key.encode()).decode()
        source = self.source.read_text().replace(
            "GOV_HISTORY_CURSOR_KEY=", "GOV_HISTORY_CURSOR_KEY=" + synthetic_key)
        source = "\n".join(line for line in source.splitlines()
                           if not line.startswith("WEBHOOK_SECRET_ENCRYPTION_KEYS="))
        self.source.write_text(source + "\nWEBHOOK_SECRET_ENCRYPTION_KEYS=rotated:" + encoded + "\n")
        with self.assertRaises(envs.EnvironmentError) as error:
            self.generate()
        self.assertNotIn(encoded, str(error.exception))
        self.assertNotIn(synthetic_key, str(error.exception))

    def test_telephony_controls_reach_only_the_application(self):
        self.source.write_text(self.source.read_text().replace(
            "TELEPHONY_PROVIDER_MODE=disabled", "TELEPHONY_PROVIDER_MODE=livekit"))
        self.generate()
        application = (self.destination / "current/app.env").read_text()
        self.assertIn("TELEPHONY_PROVIDER_MODE=livekit\n", application)
        self.assertIn("TELEPHONY_RING_TIMEOUT_SECONDS=45\n", application)
        self.assertIn("TELEPHONY_MAX_DURATION_SECONDS=1800\n", application)
        for service in ("postgres", "minio", "livekit", "object-admin", "bootstrap"):
            self.assertNotIn("TELEPHONY_", (self.destination / "current" / f"{service}.env").read_text())

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
