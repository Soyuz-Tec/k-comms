from __future__ import annotations

import base64
import tempfile
import unittest
from pathlib import Path

from validate_staging_secrets import (
    AES_256_KEYS,
    BOOTSTRAP_REQUIRED,
    RUNTIME_REQUIRED,
    STAGING_RUNTIME_REQUIRED,
    validate,
)

RUNTIME_WITH_SINGLE_KEYS = RUNTIME_REQUIRED | AES_256_KEYS
STAGING_WITH_SINGLE_KEYS = STAGING_RUNTIME_REQUIRED | AES_256_KEYS


class ValidateStagingSecretsTest(unittest.TestCase):
    def test_runtime_file_requires_every_release_and_data_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secrets.env"
            self.write(
                path,
                STAGING_WITH_SINGLE_KEYS - {"PASSWORD_RECOVERY_SIGNING_KEY"},
            )

            errors = validate(path)
            self.assertIn(
                f"{path}: missing required key PASSWORD_RECOVERY_SIGNING_KEY", errors
            )

            self.write(path, STAGING_WITH_SINGLE_KEYS)
            self.assertEqual(validate(path), [])

    def test_runtime_accepts_valid_single_keys_or_valid_keyrings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            self.write(path, RUNTIME_WITH_SINGLE_KEYS)
            self.assertEqual(validate(path), [])

            keys = RUNTIME_WITH_SINGLE_KEYS - {
                "PUSH_SUBSCRIPTION_ENCRYPTION_KEY",
                "WEBHOOK_SECRET_ENCRYPTION_KEY",
            }
            keys |= {
                "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS",
                "WEBHOOK_SECRET_ENCRYPTION_KEYS",
            }
            encoded = base64.b64encode(b"k" * 32).decode("ascii")
            self.write(
                path,
                keys,
                {
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS": f"primary:{encoded}",
                    "WEBHOOK_SECRET_ENCRYPTION_KEYS": f"primary:{encoded},previous:{encoded}",
                },
            )
            self.assertEqual(validate(path), [])

    def test_bootstrap_file_requires_complete_policy_conformant_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bootstrap-secrets.env"
            self.write(path, BOOTSTRAP_REQUIRED - {"BOOTSTRAP_OWNER_PASSWORD"})

            errors = validate(path)
            self.assertIn(
                f"{path}: missing required key BOOTSTRAP_OWNER_PASSWORD", errors
            )

            self.write(
                path,
                BOOTSTRAP_REQUIRED,
                {
                    "BOOTSTRAP_TENANT_SLUG": "Invalid Slug",
                    "BOOTSTRAP_OWNER_EMAIL": "invalid",
                    "BOOTSTRAP_OWNER_PASSWORD": "short",
                },
            )
            errors = validate(path)
            self.assertTrue(any("BOOTSTRAP_TENANT_SLUG" in error for error in errors))
            self.assertTrue(any("BOOTSTRAP_OWNER_EMAIL" in error for error in errors))
            self.assertTrue(
                any("BOOTSTRAP_OWNER_PASSWORD" in error for error in errors)
            )

    def test_runtime_encryption_keys_match_the_aes_256_runtime_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secrets.env"
            self.write(
                path,
                STAGING_WITH_SINGLE_KEYS,
                {
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEY": "p" * 31,
                    "WEBHOOK_SECRET_ENCRYPTION_KEY": "w" * 33,
                },
            )

            errors = validate(path)
            self.assertTrue(
                any(
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEY must be exactly 32 bytes" in error
                    for error in errors
                )
            )
            self.assertTrue(
                any(
                    "WEBHOOK_SECRET_ENCRYPTION_KEY must be exactly 32 bytes" in error
                    for error in errors
                )
            )

            self.write(
                path,
                STAGING_WITH_SINGLE_KEYS,
                {
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEY": base64.b64encode(
                        b"p" * 32
                    ).decode("ascii"),
                    "WEBHOOK_SECRET_ENCRYPTION_KEY": "w" * 32,
                },
            )
            self.assertEqual(validate(path), [])

    def test_keyrings_reject_duplicate_ids_and_non_32_byte_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            keys = RUNTIME_WITH_SINGLE_KEYS | {"PUSH_SUBSCRIPTION_ENCRYPTION_KEYS"}
            encoded = base64.b64encode(b"too-short").decode("ascii")
            self.write(
                path,
                keys,
                {
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS": f"primary:{encoded},primary:{encoded}"
                },
            )

            errors = validate(path)
            self.assertTrue(
                any("duplicate key identifiers" in error for error in errors)
            )
            self.assertTrue(
                any("entries must encode exactly 32 bytes" in error for error in errors)
            )

    def test_webhook_encryption_rejects_reserved_legacy_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            encoded = base64.b64encode(b"k" * 32).decode("ascii")
            keys = RUNTIME_WITH_SINGLE_KEYS | {
                "WEBHOOK_SECRET_ENCRYPTION_KEY_ID",
                "WEBHOOK_SECRET_ENCRYPTION_KEYS",
            }
            self.write(
                path,
                keys,
                {
                    "WEBHOOK_SECRET_ENCRYPTION_KEY_ID": "legacy",
                    "WEBHOOK_SECRET_ENCRYPTION_KEYS": f"legacy:{encoded}",
                },
            )

            errors = validate(path)
            self.assertTrue(
                any(
                    "WEBHOOK_SECRET_ENCRYPTION_KEY_ID must not use the reserved legacy identifier"
                    in error
                    for error in errors
                )
            )
            self.assertTrue(
                any(
                    "WEBHOOK_SECRET_ENCRYPTION_KEYS must not contain the reserved legacy identifier"
                    in error
                    for error in errors
                )
            )

    def test_security_tokens_and_release_secrets_enforce_minimum_lengths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            self.write(
                path,
                RUNTIME_WITH_SINGLE_KEYS,
                {
                    "SECRET_KEY_BASE": "s" * 63,
                    "PASSWORD_RECOVERY_SIGNING_KEY": "p" * 31,
                    "RELEASE_COOKIE": "r" * 31,
                    "METRICS_BEARER_TOKEN": "m" * 31,
                },
            )

            errors = validate(path)
            for key in (
                "SECRET_KEY_BASE",
                "PASSWORD_RECOVERY_SIGNING_KEY",
                "RELEASE_COOKIE",
                "METRICS_BEARER_TOKEN",
            ):
                self.assertTrue(any(key in error for error in errors), key)

    def test_staging_credentials_must_match_the_services_the_overlay_creates(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secrets.env"
            self.write(
                path,
                STAGING_WITH_SINGLE_KEYS,
                {
                    "POSTGRES_PASSWORD": "different-postgres-password",
                    "S3_SECRET_ACCESS_KEY": "different-minio-password",
                },
            )

            errors = validate(path)
            self.assertTrue(
                any(
                    "POSTGRES_PASSWORD must match DATABASE_URL" in error
                    for error in errors
                )
            )
            self.assertTrue(
                any(
                    "S3_SECRET_ACCESS_KEY must match MINIO_ROOT_PASSWORD" in error
                    for error in errors
                )
            )

    def test_errors_never_echo_secret_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            sentinel = "do-not-print-this-secret"
            self.write(
                path,
                RUNTIME_WITH_SINGLE_KEYS,
                {"DATABASE_URL": sentinel, "METRICS_BEARER_TOKEN": sentinel},
            )

            errors = validate(path)
            self.assertTrue(errors)
            self.assertNotIn(sentinel, "\n".join(errors))

    @staticmethod
    def write(
        path: Path, keys: set[str], overrides: dict[str, str] | None = None
    ) -> None:
        postgres_password = "postgres-password-32-bytes-long"
        minio_password = "minio-password-32-bytes-long-xx"
        values = {
            "DATABASE_URL": f"ecto://kcomms:{postgres_password}@postgres:5432/k_comms",
            "SECRET_KEY_BASE": "s" * 64,
            "PASSWORD_RECOVERY_SIGNING_KEY": "r" * 32,
            "RELEASE_COOKIE": "c" * 32,
            "S3_ACCESS_KEY_ID": "kcomms",
            "S3_SECRET_ACCESS_KEY": minio_password,
            "WEBHOOK_SECRET_ENCRYPTION_KEY": "w" * 32,
            "PUSH_SUBSCRIPTION_ENCRYPTION_KEY": "p" * 32,
            "METRICS_BEARER_TOKEN": "m" * 32,
            "POSTGRES_USER": "kcomms",
            "POSTGRES_PASSWORD": postgres_password,
            "POSTGRES_DB": "k_comms",
            "MINIO_ROOT_USER": "kcomms",
            "MINIO_ROOT_PASSWORD": minio_password,
            "BOOTSTRAP_TENANT_NAME": "K-Comms Test",
            "BOOTSTRAP_TENANT_SLUG": "k-comms-test",
            "BOOTSTRAP_OWNER_DISPLAY_NAME": "Test Owner",
            "BOOTSTRAP_OWNER_EMAIL": "owner@example.test",
            "BOOTSTRAP_OWNER_PASSWORD": "correct-horse-test-owner",
            **(overrides or {}),
        }
        path.write_text(
            "\n".join(f"{key}={values.get(key, 'x' * 32)}" for key in sorted(keys))
            + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
