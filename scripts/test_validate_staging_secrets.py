from __future__ import annotations

import base64
import tempfile
import unittest
from pathlib import Path

from validate_staging_secrets import (
    AES_256_KEYS,
    BOOTSTRAP_REQUIRED,
    RUNTIME_REQUIRED,
    PROVIDER_REQUIRED,
    STAGING_RUNTIME_REQUIRED,
    validate,
)

RUNTIME_WITH_SINGLE_KEYS = RUNTIME_REQUIRED | AES_256_KEYS
STAGING_WITH_SINGLE_KEYS = STAGING_RUNTIME_REQUIRED | AES_256_KEYS


class ValidateStagingSecretsTest(unittest.TestCase):
    def test_provider_file_requires_non_placeholder_livekit_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "provider-secrets.env"
            self.write(path, PROVIDER_REQUIRED - {"LIVEKIT_API_SECRET"})

            errors = validate(path)
            self.assertIn(f"{path}: missing required key LIVEKIT_API_SECRET", errors)

            self.write(
                path,
                PROVIDER_REQUIRED,
                {"LIVEKIT_API_KEY": "short", "LIVEKIT_API_SECRET": "too-short"},
            )
            errors = validate(path)
            self.assertTrue(any("LIVEKIT_API_KEY" in error for error in errors))
            self.assertTrue(any("LIVEKIT_API_SECRET" in error for error in errors))

            self.write(
                path,
                PROVIDER_REQUIRED,
                {"LIVEKIT_API_KEY": "production-key", "LIVEKIT_API_SECRET": "s" * 32},
            )
            self.assertEqual(validate(path), [])

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
            push_encoded = base64.b64encode(b"p" * 32).decode("ascii")
            webhook_primary = base64.b64encode(b"w" * 32).decode("ascii")
            webhook_previous = base64.b64encode(b"x" * 32).decode("ascii")
            self.write(
                path,
                keys,
                {
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS": f"primary:{push_encoded}",
                    "WEBHOOK_SECRET_ENCRYPTION_KEYS": (
                        f"primary:{webhook_primary},previous:{webhook_previous}"
                    ),
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

    def test_keyrings_require_the_active_id_and_distinct_material(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            shared = base64.b64encode(b"k" * 32).decode("ascii")
            keys = RUNTIME_REQUIRED | {
                "WEBHOOK_SECRET_ENCRYPTION_KEY_ID",
                "WEBHOOK_SECRET_ENCRYPTION_KEYS",
                "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS",
            }
            self.write(
                path,
                keys,
                {
                    "WEBHOOK_SECRET_ENCRYPTION_KEY_ID": "primary",
                    "WEBHOOK_SECRET_ENCRYPTION_KEYS": f"retired:{shared}",
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS": f"primary:{shared}",
                },
            )

            errors = validate(path)
            self.assertTrue(any("must contain the active key id" in error for error in errors))
            self.assertTrue(
                any("must not be reused across" in error for error in errors)
            )

    def test_keyring_rejects_duplicate_material_under_different_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            shared = base64.b64encode(b"k" * 32).decode("ascii")
            push = base64.b64encode(b"p" * 32).decode("ascii")
            keys = RUNTIME_REQUIRED | {
                "WEBHOOK_SECRET_ENCRYPTION_KEYS",
                "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS",
            }
            self.write(
                path,
                keys,
                {
                    "WEBHOOK_SECRET_ENCRYPTION_KEYS": (
                        f"primary:{shared},previous:{shared}"
                    ),
                    "PUSH_SUBSCRIPTION_ENCRYPTION_KEYS": f"primary:{push}",
                },
            )

            errors = validate(path)
            self.assertTrue(any("contains duplicate key material" in error for error in errors))

    def test_database_url_cannot_override_runtime_tls_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime-secrets.env"
            self.write(
                path,
                RUNTIME_WITH_SINGLE_KEYS,
                {
                    "DATABASE_URL": (
                        "ecto://kcomms:postgres-password-32-bytes-long"
                        "@postgres:5432/k_comms?ssl=false"
                    )
                },
            )

            errors = validate(path)
            self.assertTrue(any("must not override the runtime TLS policy" in error for error in errors))

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
                {"POSTGRES_PASSWORD": "different-postgres-password"},
            )

            errors = validate(path)
            self.assertTrue(
                any(
                    "POSTGRES_PASSWORD must match DATABASE_URL" in error
                    for error in errors
                )
            )

    def test_application_object_credentials_must_not_reuse_the_minio_root_identity(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secrets.env"
            self.write(
                path,
                STAGING_WITH_SINGLE_KEYS,
                {
                    "S3_ACCESS_KEY_ID": "kcomms",
                    "S3_SECRET_ACCESS_KEY": "minio-password-32-bytes-long-xx",
                },
            )

            errors = validate(path)
            for key in ("S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"):
                self.assertTrue(
                    any(f"{key} must not reuse" in error for error in errors), key
                )

            self.write(path, STAGING_WITH_SINGLE_KEYS)
            self.assertEqual(validate(path), [])

    def test_staging_requires_a_usable_object_encryption_kms_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secrets.env"

            self.write(
                path,
                STAGING_WITH_SINGLE_KEYS - {"MINIO_KMS_SECRET_KEY"},
            )
            self.assertIn(
                f"{path}: missing required key MINIO_KMS_SECRET_KEY", validate(path)
            )

            for invalid, expected in (
                ("no-separator-present", "must be key_name:Base64Key"),
                ("kcomms-key:not-base64!!", "must encode exactly 32 bytes"),
                (
                    "kcomms-key:" + base64.b64encode(b"too-short").decode(),
                    "must encode exactly 32 bytes",
                ),
            ):
                self.write(
                    path,
                    STAGING_WITH_SINGLE_KEYS,
                    {"MINIO_KMS_SECRET_KEY": invalid},
                )
                errors = validate(path)
                self.assertTrue(
                    any(expected in error for error in errors), (invalid, errors)
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
        application_password = "kcomms-app-password-32-bytes-xx"
        kms_material = base64.b64encode(b"k-comms-staging-sse-s3-key-00001").decode()
        values = {
            "DATABASE_URL": f"ecto://kcomms:{postgres_password}@postgres:5432/k_comms",
            "SECRET_KEY_BASE": "s" * 64,
            "PASSWORD_RECOVERY_SIGNING_KEY": "r" * 32,
            "RELEASE_COOKIE": "c" * 32,
            # Deliberately distinct from the MinIO root identity below.
            "S3_ACCESS_KEY_ID": "kcomms-app",
            "S3_SECRET_ACCESS_KEY": application_password,
            "MINIO_KMS_SECRET_KEY": f"kcomms-staging-key:{kms_material}",
            "WEBHOOK_SECRET_ENCRYPTION_KEY": "w" * 32,
            "PUSH_SUBSCRIPTION_ENCRYPTION_KEY": "p" * 32,
            "METRICS_BEARER_TOKEN": "m" * 32,
            "POSTGRES_USER": "kcomms",
            "POSTGRES_PASSWORD": postgres_password,
            "POSTGRES_DB": "k_comms",
            "MINIO_ROOT_USER": "kcomms",
            "MINIO_ROOT_PASSWORD": minio_password,
            "LIVEKIT_API_KEY": "production-key",
            "LIVEKIT_API_SECRET": "l" * 32,
            "NOTIFICATION_PROVIDER_TOKEN": "n" * 32,
            "ATTACHMENT_SCANNER_TOKEN": "a" * 32,
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
