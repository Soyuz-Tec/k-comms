from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from validate_architecture import (
    ALLOWED_UMBRELLA_DEPENDENCIES,
    REPO_ACCESS_ALLOWLIST,
    validate,
)


class ValidateArchitectureTest(unittest.TestCase):
    def test_accepts_the_documented_dependency_and_repo_policy(self) -> None:
        with self.repository_fixture() as root:
            self.assertEqual(validate(root), [])

    def test_rejects_a_forbidden_umbrella_dependency_edge(self) -> None:
        with self.repository_fixture() as root:
            self.write_mix(root, "comms_core", ("comms_workers",))

            self.assertIn(
                "apps/comms_core/mix.exs: forbidden umbrella dependency "
                "comms_core -> comms_workers",
                validate(root),
            )

    def test_rejects_an_unclassified_umbrella_application(self) -> None:
        with self.repository_fixture() as root:
            self.write_mix(root, "comms_future", ())

            self.assertIn(
                "apps/comms_future/mix.exs: umbrella app is not classified in the "
                "architecture policy",
                validate(root),
            )

    def test_rejects_core_module_string_and_otp_app_adapter_references(self) -> None:
        forbidden_references = (
            "CommsWorkers.OutboxWorker",
            '"CommsIntegrations.ObjectStorage"',
            ":comms_web",
            'Application.ensure_all_started(:comms_observability)',
        )

        for reference in forbidden_references:
            with self.subTest(reference=reference), self.repository_fixture() as root:
                path = root / "apps/comms_core/lib/comms_core/boundary.ex"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(
                    f"defmodule CommsCore.Boundary do\n  @adapter {reference}\nend\n",
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any(
                        "comms_core references an adapter application" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_allows_adapter_binding_in_composition_root_and_test_sources(self) -> None:
        with self.repository_fixture() as root:
            config = root / "config/config.exs"
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text(
                "config :comms_core, worker: CommsWorkers.OutboxWorker\n",
                encoding="utf-8",
            )
            test = root / "apps/comms_core/test/boundary_test.exs"
            test.parent.mkdir(parents=True, exist_ok=True)
            test.write_text(
                "assert CommsWorkers.OutboxWorker\n",
                encoding="utf-8",
            )

            self.assertEqual(validate(root), [])

    def test_rejects_qualified_and_grouped_direct_repo_access(self) -> None:
        forbidden_sources = (
            "alias CommsCore.Repo\n",
            "alias CommsCore.{Accounts, Repo}\n",
            "alias CommsCore.{\n  Accounts,\n  Repo\n}\n",
            "CommsCore.Repo.all(Query)\n",
        )

        for source in forbidden_sources:
            with self.subTest(source=source), self.repository_fixture() as root:
                path = root / "apps/comms_workers/lib/comms_workers/unsafe.ex"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")

                self.assertIn(
                    "apps/comms_workers/lib/comms_workers/unsafe.ex: direct "
                    "CommsCore.Repo access is not allowlisted",
                    validate(root),
                )

    def test_rejects_repo_access_in_web_operational_controllers(self) -> None:
        with self.repository_fixture() as root:
            path = (
                root
                / "apps/comms_web/lib/comms_web/controllers/health_controller.ex"
            )
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("alias CommsCore.Repo\n", encoding="utf-8")

            self.assertIn(
                "apps/comms_web/lib/comms_web/controllers/health_controller.ex: "
                "direct CommsCore.Repo access is not allowlisted",
                validate(root),
            )

    def test_rejects_stale_repo_allowlist_entries(self) -> None:
        with self.repository_fixture() as root:
            allowlisted = next(iter(REPO_ACCESS_ALLOWLIST))
            (root / allowlisted).unlink()

            self.assertIn(
                f"{allowlisted}: Repo-access allowlist entry does not exist",
                validate(root),
            )

    def test_rejects_an_allowlist_entry_that_no_longer_uses_repo(self) -> None:
        with self.repository_fixture() as root:
            allowlisted = next(iter(REPO_ACCESS_ALLOWLIST))
            (root / allowlisted).write_text("defmodule Safe do\nend\n", encoding="utf-8")

            self.assertIn(
                f"{allowlisted}: Repo-access allowlist entry is no longer used",
                validate(root),
            )

    def repository_fixture(self):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)

        for app, dependencies in ALLOWED_UMBRELLA_DEPENDENCIES.items():
            self.write_mix(root, app, tuple(sorted(dependencies)))

        for path in REPO_ACCESS_ALLOWLIST:
            source = root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("alias CommsCore.Repo\n", encoding="utf-8")

        class FixtureContext:
            def __enter__(self):
                return root

            def __exit__(self, exc_type, exc_value, traceback):
                temporary.cleanup()

        return FixtureContext()

    @staticmethod
    def write_mix(root: Path, app: str, dependencies: tuple[str, ...]) -> None:
        path = root / f"apps/{app}/mix.exs"
        path.parent.mkdir(parents=True, exist_ok=True)
        rendered_dependencies = "\n".join(
            f"      {{:{dependency}, in_umbrella: true}},"
            for dependency in dependencies
        )
        path.write_text(
            "defmodule Fixture.MixProject do\n"
            "  use Mix.Project\n"
            "  defp deps do\n"
            "    [\n"
            f"{rendered_dependencies}\n"
            "    ]\n"
            "  end\n"
            "end\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
