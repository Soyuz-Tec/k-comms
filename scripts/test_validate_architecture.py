from __future__ import annotations

import copy
import re
import tempfile
import unittest
from pathlib import Path

import yaml

from validate_architecture import (
    ALLOWED_UMBRELLA_DEPENDENCIES,
    REPO_ACCESS_ALLOWLIST,
    TEMPORARY_EXACT_MAPPING_POLICY,
    analyze_context_boundaries,
    canonical_text_sha256,
    compare_boundary_baselines,
    compare_boundary_manifests,
    context_cycle_violations,
    context_graphs,
    core_module_declarations,
    core_module_references,
    discover_schemas,
    generated_report_errors,
    main,
    qualified_function_calls,
    read_yaml,
    strict_deferral_rejection_reason,
    validate,
    write_baseline,
    write_current_baseline,
)


class ValidateArchitectureTest(unittest.TestCase):
    def test_accepts_the_documented_dependency_and_repo_policy(self) -> None:
        with self.repository_fixture() as root:
            self.assertEqual(validate(root), [])

    def test_missing_boundary_manifest_fails_validation_and_baseline_write(
        self,
    ) -> None:
        with self.repository_fixture() as root:
            (root / "docs/02-architecture/context-boundaries.yaml").unlink()

            self.assertTrue(
                any(
                    "required boundary manifest is missing" in error
                    for error in validate(root)
                )
            )
            with self.assertRaisesRegex(ValueError, "manifest is missing or invalid"):
                write_current_baseline(root)

    def test_missing_boundary_baseline_fails_normal_validation_but_can_be_written(
        self,
    ) -> None:
        with self.repository_fixture() as root:
            baseline = root / "docs/02-architecture/context-boundary-baseline.yaml"
            baseline.unlink()
            errors = validate(root)
            self.assertTrue(
                any(
                    "required boundary baseline is missing" in error for error in errors
                ),
                errors,
            )
            write_current_baseline(root)
            self.assertTrue(baseline.is_file())
            self.assertEqual(validate(root), [])

    def test_invalid_boundary_manifest_fails_validation_and_baseline_write(
        self,
    ) -> None:
        with self.repository_fixture() as root:
            manifest = root / "docs/02-architecture/context-boundaries.yaml"
            manifest.write_text("contexts: [not-a-mapping\n", encoding="utf-8")

            self.assertTrue(
                any(
                    "cannot load boundary manifest" in error for error in validate(root)
                )
            )
            with self.assertRaisesRegex(ValueError, "manifest is missing or invalid"):
                write_current_baseline(root)

    def test_rejects_duplicate_yaml_mapping_keys_at_every_depth(self) -> None:
        duplicate_documents = (
            "version: 1\nversion: 2\n",
            "contexts:\n  alpha:\n    public_facades: []\n"
            "    public_facades: [CommsCore.Alpha]\n",
        )
        for document in duplicate_documents:
            with self.subTest(document=document), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "manifest.yaml"
                path.write_text(document, encoding="utf-8")
                with self.assertRaisesRegex(
                    yaml.YAMLError,
                    "found duplicate mapping key",
                ):
                    read_yaml(path)

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
            "Application.ensure_all_started(:comms_observability)",
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
            "alias(CommsCore.{Accounts, Repo})\n",
            "CommsCore.Repo.all(Query)\n",
            "alias CommsCore, as: Core\nalias Core.Repo\n",
            "alias(CommsCore, as: Core)\nalias(Core.Repo)\n",
            "Elixir.CommsCore.Repo.all(Query)\n",
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

    def test_parses_grouped_aliases_from_the_comms_core_root(self) -> None:
        references = core_module_references(
            "alias CommsCore.{Accounts, Messaging}\n"
            "alias CommsCore.Administration.{InvitationView}\n"
            "alias(CommsCore.{Outbox, Repo})\n"
        )

        self.assertEqual(
            references,
            {
                "CommsCore.Accounts",
                "CommsCore.Messaging",
                "CommsCore.Administration",
                "CommsCore.Administration.InvitationView",
                "CommsCore.Outbox",
                "CommsCore.Repo",
            },
        )

    def test_parses_nested_grouped_and_chained_core_aliases(self) -> None:
        references = core_module_references(
            "alias CommsCore.{Beta.Record, Gamma}\n"
            "alias CommsCore.Beta\n"
            "alias Beta.NestedRecord\n"
        )

        self.assertTrue(
            {
                "CommsCore.Beta.Record",
                "CommsCore.Gamma",
                "CommsCore.Beta",
                "CommsCore.Beta.NestedRecord",
            }.issubset(references),
            references,
        )

    def test_module_reference_lexer_ignores_elixir_prose_and_literals(self) -> None:
        source = (
            "# CommsCore.CommentOnly\n"
            '@moduledoc """\n'
            "CommsCore.ModuleDocOnly\n"
            "alias CommsCore.FakeDocAlias\n"
            "defmodule CommsCore.FakeDocModule do\nend\n"
            '"""\n'
            '@doc "CommsCore.DocOnly"\n'
            '@string "escaped \\"CommsCore.EscapedStringOnly\\""\n'
            "@charlist 'CommsCore.CharlistOnly'\n"
            "@charlist_heredoc '''\nCommsCore.CharlistHeredocOnly\n'''\n"
            "@regex ~r/CommsCore.RegexOnly\\/[A-Z]+/iu\n"
            "@literal_sigil ~S|CommsCore.UpperSigilOnly #{CommsCore.NotInterpolated}|\n"
            '@sigil_heredoc ~S"""\nCommsCore.SigilHeredocOnly\n"""\n'
            "@word_sigil ~w(CommsCore.WordSigilOnly)a\n"
            '@interpolated "label #{CommsCore.InterpolatedCall.run()}"\n'
            "alias CommsCore.{ActualAlias, Actual.Nested}\n"
            "@type t :: CommsCore.ActualType.t()\n"
            "@spec run(CommsCore.ActualSpec.t()) :: CommsCore.ActualResult.t()\n"
            "def run(%CommsCore.ActualStruct{} = value) do\n"
            "  {&CommsCore.ActualCapture.run/1, CommsCore.ActualCall.run(value)}\n"
            "end\n"
        )

        references = core_module_references(source)

        self.assertEqual(
            references,
            {
                "CommsCore.Actual.Nested",
                "CommsCore.ActualAlias",
                "CommsCore.ActualCall",
                "CommsCore.ActualCapture",
                "CommsCore.ActualResult",
                "CommsCore.ActualSpec",
                "CommsCore.ActualStruct",
                "CommsCore.ActualType",
                "CommsCore.InterpolatedCall",
            },
        )

    def test_module_lexer_preserves_calls_and_arity_outside_literals(self) -> None:
        source = (
            '@doc "CommsCore.Fake.call(:one, :two)"\n'
            "alias CommsCore.Real, as: Boundary\n"
            "def run do\n"
            "  Boundary.execute(\"closing ) and comma ,\", ~r/(one,two)/, 'a,b')\n"
            "end\n"
        )

        self.assertEqual(
            qualified_function_calls(source),
            {("CommsCore.Real", "execute", 3)},
        )

    def test_module_declarations_ignore_examples_inside_module_docs(self) -> None:
        source = (
            "defmodule CommsCore.Real do\n"
            '  @moduledoc """\n'
            "  defmodule CommsCore.Example do\n"
            "    alias CommsCore.Fake\n"
            "  end\n"
            '  """\n'
            "end\n"
        )

        self.assertEqual(core_module_declarations(source), ["CommsCore.Real"])

    def test_compiled_graph_ignores_documented_foreign_modules(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                '  @moduledoc """\n'
                "  Example: `CommsCore.Beta.read()`\n"
                "  alias CommsCore.Beta.Record\n"
                '  """\n'
                "  # CommsCore.Beta.write()\n"
                '  @example "CommsCore.Beta.Record"\n'
                "  @pattern ~r/CommsCore.Beta/\n"
                "end\n",
                encoding="utf-8",
            )
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")

            self.assertEqual(
                context_graphs(root, manifest).compiled["alpha"],
                frozenset(),
            )

    def test_nested_and_chained_schema_aliases_cannot_hide_graph_edges(
        self,
    ) -> None:
        sources = (
            "  alias CommsCore.{Beta.Record}\n",
            "  alias CommsCore.Beta\n  alias Beta.Record\n",
        )
        for index, aliases in enumerate(sources):
            with self.subTest(index=index), self.boundary_fixture() as root:
                self.write_schema(
                    root,
                    "CommsCore.Beta.Record",
                    "beta_records",
                    "beta/record.ex",
                )
                source = root / "apps/comms_core/lib/comms_core/alpha.ex"
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    f"{aliases}"
                    "  def id(%Record{id: id}), do: id\n"
                    "end\n",
                    encoding="utf-8",
                )
                manifest = read_yaml(
                    root / "docs/02-architecture/context-boundaries.yaml"
                )
                violations = analyze_context_boundaries(root, manifest)

                self.assertTrue(
                    any(
                        item.rule == "foreign_schema_import"
                        and "CommsCore.Beta.Record" in item.detail
                        for item in violations
                    ),
                    [item.render() for item in violations],
                )
                self.assertTrue(
                    any(
                        item.rule == "undeclared_context_edge"
                        and "alpha -> beta" in item.detail
                        for item in violations
                    ),
                    [item.render() for item in violations],
                )

    def test_rejects_owner_lifecycle_commands_outside_governance(self) -> None:
        sources = (
            "defmodule CommsCore.Backdoor do\n"
            "  alias CommsCore.Accounts\n"
            "  def run(id, attrs, subject), do: "
            "Accounts.preflight_user_lifecycle_change(id, attrs, subject)\n"
            "end\n",
            "defmodule CommsCore.Backdoor do\n"
            "  def run(id, attrs, subject), do: "
            "CommsCore.Accounts.apply_user_lifecycle_change("
            "id, attrs, subject, [])\n"
            "end\n",
            "defmodule CommsCore.Backdoor do\n  import CommsCore.Accounts\nend\n",
            "defmodule CommsCore.Backdoor do\n"
            "  alias CommsCore.Accounts, as: Identity\n"
            "  import Identity\n"
            "end\n",
            "defmodule CommsCore.Backdoor do\n"
            "  alias CommsCore.Accounts\n"
            "  def run, do: &Accounts.apply_user_lifecycle_change/4\n"
            "end\n",
            "defmodule CommsCore.Backdoor do\n"
            "  alias CommsCore.Accounts\n"
            "  def run(id, attrs, subject), do: "
            "Accounts.preflight_user_lifecycle_change id, attrs, subject\n"
            "end\n",
            "defmodule CommsCore.Backdoor do\n"
            "  alias CommsCore.Accounts\n"
            "  def run(id, attrs, subject), do: "
            "apply(Accounts, :preflight_user_lifecycle_change, "
            "[id, attrs, subject])\n"
            "end\n",
            "defmodule CommsCore.Backdoor do\n"
            "  alias CommsCore.Accounts\n"
            "  @accounts Accounts\n"
            "  def run(id, attrs, subject), do: "
            "@accounts.preflight_user_lifecycle_change(id, attrs, subject)\n"
            "end\n",
            "defmodule CommsCore.Backdoor do\n"
            "  alias CommsCore.Accounts\n"
            "  defdelegate run(id, attrs, subject), to: Accounts, "
            "as: :preflight_user_lifecycle_change\n"
            "end\n",
        )

        for index, source in enumerate(sources):
            with self.subTest(index=index), self.repository_fixture() as root:
                path = root / f"apps/comms_workers/lib/comms_workers/unsafe_{index}.ex"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")

                errors = validate(root)
                self.assertTrue(
                    any(
                        "owner-internal lifecycle command" in error for error in errors
                    ),
                    errors,
                )

    def test_governance_file_name_does_not_bypass_lifecycle_caller_module(
        self,
    ) -> None:
        with self.repository_fixture() as root:
            path = root / "apps/comms_core/lib/comms_core/governance.ex"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "defmodule CommsCore.Backdoor do\n"
                "  alias CommsCore.Accounts\n"
                "  def run(id, attrs, subject), do: "
                "Accounts.preflight_user_lifecycle_change(id, attrs, subject)\n"
                "end\n",
                encoding="utf-8",
            )

            self.assertTrue(
                any(
                    "owner-internal lifecycle command" in error
                    for error in validate(root)
                )
            )

    def test_rejects_repo_access_in_web_operational_controllers(self) -> None:
        with self.repository_fixture() as root:
            path = (
                root / "apps/comms_web/lib/comms_web/controllers/health_controller.ex"
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
            (root / allowlisted).write_text(
                "defmodule Safe do\nend\n", encoding="utf-8"
            )

            self.assertIn(
                f"{allowlisted}: Repo-access allowlist entry is no longer used",
                validate(root),
            )

    def test_rejects_duplicate_table_mappings(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex"
            )
            self.write_schema(
                root, "CommsCore.Beta.Record", "alpha_records", "beta/record.ex"
            )

            self.assert_rule(root, "duplicate_table_mapping")

    def test_external_framework_tables_support_schema_or_accessor_declarations(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["tables"]["oban_jobs"] = {
                "owner": "alpha",
                "external_schema": True,
                "canonical_schema": "Oban.Job",
            }
            manifest["tables"]["oban_peers"] = {
                "owner": "alpha",
                "external_schema": True,
                "canonical_accessor": "Oban.Peers.Database",
            }

            violations = analyze_context_boundaries(root, manifest)
            external_errors = [
                item
                for item in violations
                if ("oban_jobs" in item.detail or "oban_peers" in item.detail)
                and item.rule in {"declared_table_missing", "invalid_table_declaration"}
            ]
            self.assertEqual(external_errors, [])

    def test_external_framework_tables_require_exactly_one_canonical_declaration(
        self,
    ) -> None:
        invalid_declarations = (
            {
                "owner": "alpha",
                "external_schema": True,
            },
            {
                "owner": "alpha",
                "external_schema": True,
                "canonical_schema": "Oban.Job",
                "canonical_accessor": "Oban.Repository",
            },
        )
        for index, declaration in enumerate(invalid_declarations):
            with self.subTest(index=index), self.boundary_fixture() as root:
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["tables"]["external_records"] = declaration

                self.assertTrue(
                    any(
                        item.rule == "invalid_table_declaration"
                        and "external_records" in item.detail
                        for item in analyze_context_boundaries(root, manifest)
                    )
                )

    def test_repository_has_one_canonical_users_schema_and_owner(self) -> None:
        root = Path(__file__).resolve().parents[1]
        schemas = discover_schemas(root)

        self.assertEqual(
            schemas["users"],
            [
                (
                    "CommsCore.Accounts.User",
                    "apps/comms_core/lib/comms_core/accounts/user.ex",
                )
            ],
        )

    def test_repository_assigns_tenants_to_tenant_administration(self) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        schemas = discover_schemas(root)

        self.assertEqual(
            schemas["tenants"],
            [
                (
                    "CommsCore.Administration.Tenant",
                    "apps/comms_core/lib/comms_core/administration/tenant.ex",
                )
            ],
        )
        self.assertEqual(
            manifest["tables"]["tenants"],
            {
                "owner": "tenant_administration",
                "canonical_schema": "CommsCore.Administration.Tenant",
                "role": "source",
            },
        )
        self.assertFalse(
            (root / "apps/comms_core/lib/comms_core/accounts/tenant.ex").exists()
        )

        identity_sources = [
            root / "apps/comms_core/lib/comms_core/accounts.ex",
            root / "apps/comms_core/lib/comms_core/password_recovery.ex",
            root / "apps/comms_core/lib/comms_core/service_accounts.ex",
            *sorted((root / "apps/comms_core/lib/comms_core/accounts").rglob("*.ex")),
            *sorted(
                (root / "apps/comms_core/lib/comms_core/service_accounts").rglob("*.ex")
            ),
        ]
        forbidden_tenant_schemas = {
            "CommsCore.Accounts.Tenant",
            "CommsCore.Administration.Tenant",
        }
        tenant_schema_leaks = []
        for path in identity_sources:
            leaked = sorted(
                core_module_references(path.read_text(encoding="utf-8")).intersection(
                    forbidden_tenant_schemas
                )
            )
            if leaked:
                tenant_schema_leaks.append((path.relative_to(root).as_posix(), leaked))
        self.assertEqual(tenant_schema_leaks, [])

        scalar_tenant_schemas = (
            "apps/comms_core/lib/comms_core/accounts/device.ex",
            "apps/comms_core/lib/comms_core/accounts/password_recovery_request.ex",
            "apps/comms_core/lib/comms_core/accounts/platform_role_grant.ex",
            "apps/comms_core/lib/comms_core/accounts/session.ex",
            "apps/comms_core/lib/comms_core/accounts/socket_ticket.ex",
            "apps/comms_core/lib/comms_core/accounts/user.ex",
            "apps/comms_core/lib/comms_core/service_accounts/service_account.ex",
        )
        for relative_path in scalar_tenant_schemas:
            with self.subTest(schema=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                self.assertIn("field(:tenant_id, Ecto.UUID)", source)
                self.assertNotIn("belongs_to(:tenant", source)

        administration = (
            root / "apps/comms_core/lib/comms_core/administration.ex"
        ).read_text(encoding="utf-8")
        for owner_api in (
            "def active_tenant(tenant_id) when is_binary(tenant_id)",
            "def active_tenant_by_slug(slug) when is_binary(slug)",
            "Repo.get_by(Tenant, id: tenant_id, status: :active)",
            "Repo.get_by(Tenant, slug: slug, status: :active)",
            "def active_tenant(_tenant_id), do: {:error, :tenant_unavailable}",
            "def active_tenant_by_slug(_slug), do: {:error, :tenant_unavailable}",
        ):
            self.assertIn(owner_api, administration)
        self.assertIn("TenantView.t()", administration)

        owner_api_consumers = {
            "apps/comms_core/lib/comms_core/accounts.ex": "Administration.active_tenant",
            "apps/comms_core/lib/comms_core/service_accounts.ex": "Administration.active_tenant",
            "apps/comms_core/lib/comms_core/accounts/password_recovery.ex": "Administration.active_tenant_by_slug",
        }
        for relative_path, owner_call in owner_api_consumers.items():
            with self.subTest(consumer=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                self.assertIn(owner_call, source)

        public_recovery = (
            root / "apps/comms_core/lib/comms_core/password_recovery.ex"
        ).read_text(encoding="utf-8")
        internal_recovery = (
            root / "apps/comms_core/lib/comms_core/accounts/password_recovery.ex"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "alias CommsCore.Accounts.PasswordRecovery, as: IdentityPasswordRecovery",
            public_recovery,
        )
        self.assertIn(
            "def reset(attrs), do: IdentityPasswordRecovery.reset(attrs)",
            public_recovery,
        )
        self.assertIn(
            "alias CommsCore.Accounts.PasswordRecoveryResult",
            public_recovery,
        )
        self.assertIn("{:ok, PasswordRecoveryResult.t()}", public_recovery)
        self.assertNotIn("Map.take", public_recovery)
        self.assertNotIn("%User{", public_recovery)
        for persistence_detail in (
            "CommsCore.Repo",
            "Ecto.Query",
            "PasswordRecoveryRequest",
            "NotificationPort",
        ):
            self.assertNotIn(persistence_detail, public_recovery)
        self.assertIn(
            "defmodule CommsCore.Accounts.PasswordRecovery do",
            internal_recovery,
        )
        self.assertIn("NotificationPort", internal_recovery)
        self.assertIn("PasswordRecoveryRequest", internal_recovery)
        self.assertIn("Repo.transaction", internal_recovery)

        recovery_result_contract = (
            root / "apps/comms_core/lib/comms_core/accounts/password_recovery_result.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("defstruct [:revoked_session_ids]", recovery_result_contract)
        self.assertNotIn("use CommsCore.Schema", recovery_result_contract)
        self.assertNotIn("use Ecto.Schema", recovery_result_contract)
        self.assertIn(
            "CommsCore.Accounts.PasswordRecoveryResult",
            manifest["contexts"]["identity_access"]["public_contracts"],
        )

        internal_recovery_adapter_leaks = []
        for app in ("comms_web", "comms_workers", "comms_integrations"):
            for path in sorted((root / f"apps/{app}/lib").rglob("*.ex")):
                references = core_module_references(path.read_text(encoding="utf-8"))
                if "CommsCore.Accounts.PasswordRecovery" in references:
                    internal_recovery_adapter_leaks.append(
                        path.relative_to(root).as_posix()
                    )
        self.assertEqual(internal_recovery_adapter_leaks, [])

        notification_collaboration = next(
            item
            for item in manifest["runtime_collaborations"]
            if item["id"] == "identity-notification-lifecycle"
        )
        self.assertEqual(
            notification_collaboration["callers"],
            ["CommsCore.Accounts", "CommsCore.Accounts.PasswordRecovery"],
        )

        transition = next(
            item
            for item in manifest["enforcement"]["reviewed_baseline_transitions"]
            if item["id"] == "assign-tenants-to-tenant-administration"
        )
        self.assertEqual(
            transition["previous_baseline_sha256"],
            "2693d8743484856dfda3bb39fa5c02214e277f50db914f341632c65b8ee97762",
        )
        self.assertEqual(
            set(transition["added_fingerprints"]),
            {
                "245ad9a0716b68dd",
                "64ebb8611dae56b3",
                "a99d73667cfe396f",
                "d4743d3326027747",
                "eb0650068879158b",
            },
        )
        self.assertEqual(
            set(transition["removed_fingerprints"]),
            {
                "2239525a78f246a4",
                "22d29c8a33ec3581",
                "242e1087dab4d610",
                "24d261bf4611f799",
                "2a53bebf9a2c2b68",
                "3d08a6a84ca380ce",
                "42cd72ee581f329d",
                "440a0becf16cccb8",
                "46833d9e4f37a9f4",
                "537281a03df0f98f",
                "6e01f546438ba1e0",
                "7e866a84330fe233",
                "82083a1e5dce0f4c",
                "830bbf4ebd3732c3",
                "8ee1149661d778c8",
                "9c00206437b708a1",
                "b881cf0b24fc1a13",
                "c3292521cd5c5918",
                "d312276f5a39310f",
            },
        )

    def test_repository_removes_accidental_identity_schema_associations(self) -> None:
        root = Path(__file__).resolve().parents[1]
        id_only_schemas = {
            "apps/comms_core/lib/comms_core/events/outbox_event.ex": (
                "field(:tenant_id, :binary_id)",
            ),
            "apps/comms_core/lib/comms_core/integrations/webhook_delivery.ex": (
                "field(:tenant_id, :binary_id)",
            ),
            "apps/comms_core/lib/comms_core/integrations/webhook_endpoint.ex": (
                "field(:tenant_id, :binary_id)",
                "field(:created_by_user_id, :binary_id)",
            ),
            "apps/comms_core/lib/comms_core/integrations/webhook_secret.ex": (
                "field(:tenant_id, :binary_id)",
            ),
            "apps/comms_core/lib/comms_core/integrations/webhook_subscription.ex": (
                "field(:tenant_id, :binary_id)",
            ),
        }

        for relative_path, required_fields in id_only_schemas.items():
            with self.subTest(path=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                self.assertNotIn("CommsCore.Accounts.Tenant", source)
                self.assertNotIn("CommsCore.Administration.Tenant", source)
                self.assertNotIn("CommsCore.Accounts.User", source)
                for field in required_fields:
                    self.assertIn(field, source)

    def test_repository_routes_message_boundary_work_through_conversations(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        source = (root / "apps/comms_core/lib/comms_core/messaging.ex").read_text(
            encoding="utf-8"
        )
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        references = core_module_references(source)

        self.assertIn("Conversations.reserve_message_slot", source)
        self.assertIn("Conversations.validate_active_members", source)
        self.assertIn("Conversations.active_conversation_ids", source)
        self.assertTrue(
            {
                "CommsCore.Accounts.User",
                "CommsCore.Conversations.Conversation",
                "CommsCore.Conversations.Membership",
            }.isdisjoint(references),
            references,
        )
        self.assertIn(
            "CommsCore.Conversations.MessageWriteSlot",
            manifest["contexts"]["conversations"]["public_contracts"],
        )

    def test_repository_contains_conversations_persistence_behind_owner_apis(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        conversations_root = root / "apps/comms_core/lib/comms_core/conversations"
        conversation_sources = [
            root / "apps/comms_core/lib/comms_core/conversations.ex",
            *sorted(conversations_root.rglob("*.ex")),
        ]
        forbidden_identity_internals = {
            "CommsCore.Accounts.Projector",
            "CommsCore.Accounts.Tenant",
            "CommsCore.Administration.Tenant",
            "CommsCore.Accounts.User",
        }
        foreign_references = []

        for path in conversation_sources:
            references = core_module_references(path.read_text(encoding="utf-8"))
            leaked = sorted(references.intersection(forbidden_identity_internals))
            if leaked:
                foreign_references.append((path.relative_to(root).as_posix(), leaked))

        self.assertEqual(foreign_references, [])

        scalar_fields = {
            "conversation.ex": (
                "field(:tenant_id, Ecto.UUID)",
                "field(:created_by_user_id, Ecto.UUID)",
            ),
            "membership.ex": (
                "field(:tenant_id, Ecto.UUID)",
                "field(:user_id, Ecto.UUID)",
            ),
        }
        for filename, fields in scalar_fields.items():
            with self.subTest(schema=filename):
                source = (conversations_root / filename).read_text(encoding="utf-8")
                for field in fields:
                    self.assertIn(field, source)

        conversations_source = conversation_sources[0].read_text(encoding="utf-8")
        self.assertIn("Accounts.resolve_active_user_ids(", conversations_source)
        self.assertIn("Accounts.resolve_user_views(", conversations_source)
        self.assertEqual(conversations_source.count("def active_member_ids("), 1)
        self.assertIn(
            "def active_member_ids(tenant_id, conversation_id)",
            conversations_source,
        )

        accounts_source = (
            root / "apps/comms_core/lib/comms_core/accounts.ex"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "def resolve_active_user_ids(tenant_id, user_ids)", accounts_source
        )
        self.assertIn("def resolve_user_views(tenant_id, user_ids)", accounts_source)
        self.assertIn(
            "CommsCore.Accounts.UserView",
            manifest["contexts"]["identity_access"]["public_contracts"],
        )

        active_member_callers = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            for module, function, arity in qualified_function_calls(
                path.read_text(encoding="utf-8")
            ):
                if (
                    module == "CommsCore.Conversations"
                    and function == "active_member_ids"
                ):
                    active_member_callers.append(
                        (path.relative_to(root).as_posix(), arity)
                    )

        self.assertTrue(active_member_callers)
        self.assertTrue(
            all(arity == 2 for _path, arity in active_member_callers),
            active_member_callers,
        )

    def test_repository_keeps_audit_persistence_inside_the_audit_implementation(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        audit_table = manifest["tables"]["audit_events"]

        self.assertEqual(audit_table["access"], "owner_only")
        self.assertEqual(audit_table["access_namespaces"], ["CommsCore.Audit"])
        self.assertEqual(
            manifest["contexts"]["audit"]["public_contracts"],
            [
                "CommsCore.Audit.Actor",
                "CommsCore.Audit.Event",
                "CommsCore.Audit.Error",
            ],
        )

        allowed = {
            "apps/comms_core/lib/comms_core/audit.ex",
            "apps/comms_core/lib/comms_core/audit/audit_event.ex",
        }
        offenders = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            text = path.read_text(encoding="utf-8")
            if "AuditEvent" in text or '"audit_events"' in text:
                relative_path = path.relative_to(root).as_posix()
                if relative_path not in allowed:
                    offenders.append(relative_path)

        self.assertEqual(offenders, [])

    def test_repository_enforces_the_conversation_content_direction_and_contracts(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        content = manifest["contexts"]["conversation_content"]

        self.assertEqual(content["current_contexts"], ["Messaging", "Attachments"])
        self.assertEqual(content["fold_in"], ["Attachments"])
        self.assertEqual(
            content["public_contracts"],
            [
                "CommsCore.Messaging.MessageView",
                "CommsCore.Messaging.MessageDeletionCandidate",
                "CommsCore.Messaging.GovernanceImpact",
                "CommsCore.Messaging.RetentionScope",
                "CommsCore.Messaging.RetentionCandidate",
                "CommsCore.Messaging.ReactionView",
                "CommsCore.Attachments.AttachmentDeletionObject",
                "CommsCore.Attachments.AttachmentView",
                "CommsCore.Attachments.RestoreCandidate",
                "CommsCore.Attachments.RestoreContext",
                "CommsCore.Attachments.RestoreReport",
                "CommsCore.Attachments.RestoredObjectIdentity",
                "CommsCore.Attachments.ScanAttemptView",
            ],
        )
        self.assertNotIn("trust_governance", content["allowed_dependencies"])
        self.assertNotIn(
            "CommsCore.Governance",
            (root / "apps/comms_core/lib/comms_core/messaging.ex").read_text(
                encoding="utf-8"
            ),
        )
        message_controller = (
            root / "apps/comms_web/lib/comms_web/controllers/message_controller.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("Governance.delete_message", message_controller)
        self.assertNotIn("Messaging.delete_message", message_controller)
        self.assertIn(
            {
                "id": "attachments-do-not-depend-on-messaging",
                "from": "CommsCore.Attachments",
                "forbidden": ["CommsCore.Messaging"],
                "condition": (
                    "Messaging orchestrates transactional attachment claiming by IDs; "
                    "Attachments must not import message schemas or implementation modules."
                ),
            },
            manifest["namespace_dependency_rules"],
        )
        self.assertIn(
            {
                "id": "service-accounts-do-not-depend-on-conversation-content",
                "from": "CommsCore.ServiceAccounts",
                "forbidden": [
                    "CommsCore.Messaging",
                    "CommsCore.Attachments",
                ],
                "condition": (
                    "ConversationContent owns service message reads, writes, search, and "
                    "attachment policy; ServiceAccounts supplies only identity and scoped "
                    "capability validation."
                ),
            },
            manifest["namespace_dependency_rules"],
        )
        self.assertIn(
            {
                "id": "accounts-do-not-depend-on-conversations",
                "from": "CommsCore.Accounts",
                "forbidden": ["CommsCore.Conversations"],
                "condition": (
                    "IdentityAccess composes the initial channel through its "
                    "transaction-scoped bootstrap port; Accounts must not import "
                    "Conversations facades, contracts, schemas, or implementation modules."
                ),
            },
            manifest["namespace_dependency_rules"],
        )
        self.assertIn(
            {
                "id": "service-accounts-do-not-depend-on-conversations",
                "from": "CommsCore.ServiceAccounts",
                "forbidden": ["CommsCore.Conversations"],
                "condition": (
                    "Conversations owns service directory and membership policy; "
                    "ServiceAccounts validates only the durable service identity and "
                    "requested capability."
                ),
            },
            manifest["namespace_dependency_rules"],
        )

        reverse_dependencies = []
        attachment_root = root / "apps/comms_core/lib/comms_core/attachments"
        attachment_sources = [
            root / "apps/comms_core/lib/comms_core/attachments.ex",
            *sorted(attachment_root.rglob("*.ex")),
        ]
        for path in attachment_sources:
            if "CommsCore.Messaging" in path.read_text(encoding="utf-8"):
                reverse_dependencies.append(path.relative_to(root).as_posix())
        self.assertEqual(reverse_dependencies, [])

        service_accounts_source = (
            root / "apps/comms_core/lib/comms_core/service_accounts.ex"
        ).read_text(encoding="utf-8")
        self.assertTrue(
            core_module_references(service_accounts_source).isdisjoint(
                {"CommsCore.Messaging", "CommsCore.Attachments"}
            )
        )

        messaging_source = (
            root / "apps/comms_core/lib/comms_core/messaging.ex"
        ).read_text(encoding="utf-8")
        for public_api in (
            "def list_service_history(",
            "def accept_service_message_with_status(",
            "def search_for_service(",
        ):
            self.assertIn(public_api, messaging_source)
        self.assertIn("authorize: &service_authorizer/3", messaging_source)
        self.assertIn(
            'Conversations.authorize_service_access(subject, "messages:write", id)',
            messaging_source,
        )

        for controller in (
            "service_message_controller.ex",
            "service_search_controller.ex",
        ):
            source = (
                root / f"apps/comms_web/lib/comms_web/controllers/{controller}"
            ).read_text(encoding="utf-8")
            self.assertIn("CommsCore.Messaging", source)
            self.assertNotIn("CommsCore.ServiceAccounts", source)

        persistence_modules = (
            "CommsCore.Messaging.Message",
            "CommsCore.Messaging.Reaction",
            "CommsCore.Attachments.Attachment",
            "CommsCore.Attachments.ScanAttempt",
        )
        adapter_leaks = []
        for app in ("comms_web", "comms_workers", "comms_integrations"):
            for path in sorted((root / f"apps/{app}/lib").rglob("*.ex")):
                text = path.read_text(encoding="utf-8")
                for module in persistence_modules:
                    if module in text and f"{module}View" not in text:
                        adapter_leaks.append(
                            (path.relative_to(root).as_posix(), module)
                        )
        self.assertEqual(adapter_leaks, [])
        self.assertEqual(
            manifest["tables"]["users"],
            {
                "owner": "identity_access",
                "canonical_schema": "CommsCore.Accounts.User",
                "role": "source",
            },
        )

    def test_repository_contains_conversation_content_persistence_and_restore_seams(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)

        scalar_fields = {
            "apps/comms_core/lib/comms_core/messaging/message.ex": (
                "tenant_id",
                "conversation_id",
                "sender_user_id",
                "sender_device_id",
            ),
            "apps/comms_core/lib/comms_core/messaging/message_mention.ex": (
                "tenant_id",
                "user_id",
            ),
            "apps/comms_core/lib/comms_core/messaging/message_revision.ex": (
                "tenant_id",
                "editor_user_id",
            ),
            "apps/comms_core/lib/comms_core/messaging/reaction.ex": (
                "tenant_id",
                "user_id",
            ),
            "apps/comms_core/lib/comms_core/attachments/attachment.ex": (
                "tenant_id",
                "owner_user_id",
            ),
            "apps/comms_core/lib/comms_core/attachments/scan_attempt.ex": (
                "tenant_id",
            ),
        }
        schema_paths = set(scalar_fields)
        foreign_schema_violations = [
            (item.path, item.detail)
            for item in violations
            if item.rule == "foreign_schema_import" and item.path in schema_paths
        ]
        self.assertEqual(foreign_schema_violations, [])

        for relative_path, fields in scalar_fields.items():
            with self.subTest(schema=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                for field in fields:
                    self.assertIn(f"field(:{field}, Ecto.UUID)", source)

        tenant_contracts = set(
            manifest["contexts"]["tenant_administration"]["public_contracts"]
        )
        self.assertIn(
            "CommsCore.Administration.ConversationContentPolicy",
            tenant_contracts,
        )

        policy_source = (
            root / "apps/comms_core/lib/comms_core/administration/"
            "conversation_content_policy.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("defstruct", policy_source)
        self.assertNotIn("use CommsCore.Schema", policy_source)
        self.assertNotIn("use Ecto.Schema", policy_source)

        for relative_path in (
            "apps/comms_core/lib/comms_core/messaging.ex",
            "apps/comms_core/lib/comms_core/attachments.ex",
        ):
            with self.subTest(policy_consumer=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                self.assertIn("Administration.conversation_content_policy", source)
                self.assertIn("Administration.ConversationContentPolicy", source)
                self.assertNotIn("Administration.member_capabilities", source)

        restore_contracts = {
            "CommsCore.Attachments.RestoreCandidate": "apps/comms_core/lib/comms_core/attachments/restore_candidate.ex",
            "CommsCore.Attachments.RestoreContext": "apps/comms_core/lib/comms_core/attachments/restore_context.ex",
            "CommsCore.Attachments.RestoreReport": "apps/comms_core/lib/comms_core/attachments/restore_report.ex",
            "CommsCore.Attachments.RestoredObjectIdentity": "apps/comms_core/lib/comms_core/attachments/"
            "restored_object_identity.ex",
        }
        declared_content_contracts = set(
            manifest["contexts"]["conversation_content"]["public_contracts"]
        )
        self.assertTrue(set(restore_contracts).issubset(declared_content_contracts))
        for contract, relative_path in restore_contracts.items():
            with self.subTest(contract=contract):
                source = (root / relative_path).read_text(encoding="utf-8")
                self.assertIn("defstruct", source)
                self.assertNotIn("use CommsCore.Schema", source)
                self.assertNotIn("use Ecto.Schema", source)
                self.assertNotIn('schema "', source)

        attachments = (
            root / "apps/comms_core/lib/comms_core/attachments.ex"
        ).read_text(encoding="utf-8")
        restore_remap = (
            root / "apps/comms_core/lib/comms_core/attachments/restore_remap.ex"
        ).read_text(encoding="utf-8")
        release = (root / "apps/comms_core/lib/comms_core/release.ex").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            "def remap_restored_attachment_versions(verifier, %RestoreContext{} = context)",
            attachments,
        )
        self.assertIn("RestoreCandidate.t()", attachments)
        self.assertIn("RestoredObjectIdentity.t()", attachments)
        self.assertIn("%RestoreCandidate{", restore_remap)
        self.assertIn("verifier.(candidate)", restore_remap)
        self.assertIn(
            "Attachments.remap_restored_attachment_versions(verifier, context)",
            release,
        )
        self.assertNotIn("RestoreRemap", release)

        attach_ready = attachments[attachments.index("def attach_ready(") :]
        attach_ready = attach_ready[: attach_ready.index("defp owned_for_update(")]
        self.assertIn("Repo.in_transaction?()", attach_ready)
        self.assertIn("{:error, :transaction_required}", attach_ready)
        self.assertIn("defp attach_ready_in_transaction(", attach_ready)

        transition = next(
            item
            for item in manifest["enforcement"]["reviewed_baseline_transitions"]
            if item["id"] == "contain-conversation-content-persistence"
        )
        self.assertEqual(
            transition["previous_baseline_sha256"],
            "75fb767635aaf4a695dc2f0c6e27f7d77fc4a1a42f3f5f745b0b6d30f0ccf1c5",
        )
        self.assertEqual(transition["added_fingerprints"], [])
        self.assertEqual(
            set(transition["removed_fingerprints"]),
            {
                "00fed2fc66ac6b5f",
                "0bb3a37c40cc67ed",
                "0eed2537c58046a8",
                "1e36cf5947105a60",
                "281d9add61ab8c61",
                "4d0c0c815493288e",
                "7189e4399b7315ba",
                "7ac0c7ca4d4d6af3",
                "7cefa81ef6dff66b",
                "b55f1875cf2b64d8",
                "e7095da760d0066e",
                "f1940a85836a5231",
                "f30df696bf8e3c3c",
            },
        )

    def test_repository_consolidates_notification_delivery_behind_one_facade(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        delivery = manifest["contexts"]["notification_delivery"]

        self.assertEqual(delivery["current_contexts"], ["Notifications"])
        self.assertEqual(
            delivery["fold_in"], ["InAppNotifications", "PushSubscriptions"]
        )
        self.assertEqual(delivery["public_facades"], ["CommsCore.Notifications"])
        self.assertEqual(
            delivery["public_contracts"],
            [
                "CommsCore.Notifications.AttemptView",
                "CommsCore.Notifications.Availability",
                "CommsCore.Notifications.Delivery",
                "CommsCore.Notifications.IntentView",
                "CommsCore.Notifications.PreferenceView",
                "CommsCore.Notifications.PushSubscriptionView",
            ],
        )
        self.assertIn(
            "CommsCore.Accounts.NotificationRecipient",
            manifest["contexts"]["identity_access"]["public_contracts"],
        )
        self.assertEqual(delivery["publishes"], [])
        self.assertEqual(
            delivery["consumes"],
            ["message.created.v1", "mention.created.v1"],
        )
        self.assertEqual(
            manifest["retired_modules"],
            [
                "CommsCore.Authorization",
                "CommsCore.InAppNotifications",
                "CommsCore.PushSubscriptions",
            ],
        )

        for table in (
            "notification_preferences",
            "notification_intents",
            "notification_attempts",
            "push_subscriptions",
        ):
            self.assertEqual(manifest["tables"][table]["access"], "owner_only")

        persistence_modules = {
            "CommsCore.Notifications.Attempt",
            "CommsCore.Notifications.Intent",
            "CommsCore.Notifications.Preference",
            "CommsCore.Notifications.PushSubscription",
        }
        leaks = []
        for app in ("comms_web", "comms_workers", "comms_integrations"):
            for path in sorted((root / f"apps/{app}/lib").rglob("*.ex")):
                references = core_module_references(path.read_text(encoding="utf-8"))
                for module in sorted(references.intersection(persistence_modules)):
                    leaks.append((path.relative_to(root).as_posix(), module))
        self.assertEqual(leaks, [])

        forbidden_foreign_schemas = {
            "CommsCore.Accounts.Device",
            "CommsCore.Accounts.Tenant",
            "CommsCore.Accounts.User",
            "CommsCore.Administration.Tenant",
            "CommsCore.Conversations.Membership",
        }
        notification_sources = [
            root / "apps/comms_core/lib/comms_core/notifications.ex",
            *sorted(
                (root / "apps/comms_core/lib/comms_core/notifications").rglob("*.ex")
            ),
        ]
        foreign_schema_references = []
        for path in notification_sources:
            references = core_module_references(path.read_text(encoding="utf-8"))
            leaked = sorted(references.intersection(forbidden_foreign_schemas))
            if leaked:
                foreign_schema_references.append(
                    (path.relative_to(root).as_posix(), leaked)
                )
        self.assertEqual(foreign_schema_references, [])

        schema_scalar_fields = {
            "attempt.ex": ("tenant_id",),
            "intent.ex": ("tenant_id", "user_id"),
            "preference.ex": ("tenant_id", "user_id"),
            "push_subscription.ex": ("tenant_id", "user_id", "device_id"),
        }
        schema_root = root / "apps/comms_core/lib/comms_core/notifications"
        for filename, fields in schema_scalar_fields.items():
            with self.subTest(schema=filename):
                source = (schema_root / filename).read_text(encoding="utf-8")
                for field in fields:
                    self.assertIn(f"field(:{field}, Ecto.UUID)", source)

        notifications_source = notification_sources[0].read_text(encoding="utf-8")
        self.assertIn(
            "|> Conversations.active_member_ids(conversation_id)",
            notifications_source,
        )
        self.assertIn(
            "Accounts.resolve_notification_recipients(event.tenant_id, user_ids)",
            notifications_source,
        )

        push_source = (
            root / "apps/comms_core/lib/comms_core/notifications/push_subscriptions.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("Accounts.notification_eligible_device_ids(", push_source)
        self.assertIn("Accounts.lock_push_registration_identity(", push_source)

    def test_repository_strict_gate_has_zero_boundary_debt(self) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        enforcement = manifest["enforcement"]

        self.assertEqual(enforcement["mode"], "strict")
        self.assertEqual(enforcement["target_mode"], "strict")
        self.assertIs(enforcement["reject_new_violations"], True)
        self.assertNotIn("strict_with_explicit_deferrals", enforcement)
        self.assertNotIn("baseline_adoption", enforcement)
        self.assertNotIn("temporary_violations", manifest)

        baseline = read_yaml(
            root / "docs/02-architecture/context-boundary-baseline.yaml"
        )
        self.assertEqual(baseline["violations"], [])
        self.assertEqual(analyze_context_boundaries(root, manifest), [])

        transition = next(
            item
            for item in enforcement["reviewed_baseline_transitions"]
            if item["id"] == "complete-calls-modularization"
        )
        self.assertEqual(
            transition["previous_baseline_sha256"],
            "90a52be007eecd64627b35212ec3da314e742f232373a6e954523116f4fa1da6",
        )
        self.assertEqual(transition["added_fingerprints"], [])
        self.assertEqual(
            transition["removed_fingerprints"],
            [
                "0189e4bac08f3c6e",
                "0e985916a4de06ec",
                "245ad9a0716b68dd",
                "47659f71148ad7cd",
                "4f52bd7c42b47a5d",
                "605ae97a5fa655cc",
                "64ebb8611dae56b3",
                "66c2fbf2a79936f4",
                "6af6e9564cd1b152",
                "6b641d47b77c08c7",
                "7a1ffc82ac877370",
                "7c47ce0ca3e555a9",
                "7c601f7c21a5fe6c",
                "7fbfb2c4017910ce",
                "889ca078f04b8132",
                "8dd4f3b5e1378ffb",
                "96d281b6465f8b8b",
                "99cd7470375bce8f",
                "9fa2f7bb1abcc6b0",
                "a26844eb317ed35d",
                "a99d73667cfe396f",
                "bec8b11dfcf061c7",
                "c94c7774541553d1",
                "d4743d3326027747",
                "db68fcb3dac3ef04",
                "de83107f64cbc690",
                "e3c6574035e85b56",
                "eb0650068879158b",
                "fc1a11f2a5f8452a",
            ],
        )
        self.assertEqual(validate(root), [])

        interfaces = {item["id"]: item for item in manifest["technical_interfaces"]}
        self.assertEqual(
            set(interfaces),
            {
                "notification-availability-adapter",
                "web-validation-error-rendering",
                "worker-attachment-restore-release",
                "worker-outbox-publication",
            },
        )
        self.assertEqual(
            interfaces["web-validation-error-rendering"]["operations"],
            [{"name": "from", "arity": 1}],
        )
        self.assertEqual(
            interfaces["worker-attachment-restore-release"]["callers"],
            ["CommsWorkers.Release"],
        )
        self.assertEqual(
            interfaces["worker-outbox-publication"]["operations"],
            [
                {"name": "fetch_for_publication", "arity": 2},
                {"name": "mark_published", "arity": 2},
                {"name": "record_attempt", "arity": 2},
            ],
        )
        availability = interfaces["notification-availability-adapter"]
        self.assertEqual(
            availability["behaviour"],
            "CommsCore.Notifications.AvailabilityNotifier.Contract",
        )
        self.assertEqual(
            availability["implementation"],
            "CommsWeb.NotificationAvailabilityNotifier",
        )
        self.assertEqual(
            availability["binding"],
            {
                "application": "comms_core",
                "key": "notification_availability_notifier",
                "module": "CommsWeb.NotificationAvailabilityNotifier",
            },
        )

    def test_repository_publishes_an_exact_calls_boundary_and_collaborations(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        calls = manifest["contexts"]["calls"]
        public_contracts = {
            "CommsCore.AudioCalls.CallView",
            "CommsCore.AudioCalls.CredentialRequest",
            "CommsCore.AudioCalls.EvictionClaim",
            "CommsCore.AudioCalls.EvictionProgress",
            "CommsCore.AudioCalls.ProviderCall",
        }
        internal_modules = {
            "CommsCore.AudioCalls.Access",
            "CommsCore.AudioCalls.AudioCall",
            "CommsCore.AudioCalls.AudioCallParticipant",
            "CommsCore.AudioCalls.AuthorizationPolicy",
            "CommsCore.AudioCalls.Projector",
        }

        self.assertEqual(calls["public_facades"], ["CommsCore.AudioCalls"])
        self.assertEqual(set(calls["public_contracts"]), public_contracts)
        self.assertEqual(calls["internal_namespaces"], ["CommsCore.AudioCalls"])
        self.assertEqual(
            calls["publishes"],
            [
                "audio_call.started.v1",
                "audio_call.ended.v1",
                "call.started.v1",
                "call.ended.v1",
            ],
        )
        self.assertEqual(calls["consumes"], [])
        self.assertEqual(
            {
                table: declaration["canonical_schema"]
                for table, declaration in manifest["tables"].items()
                if declaration["owner"] == "calls"
            },
            {
                "audio_call_participants": (
                    "CommsCore.AudioCalls.AudioCallParticipant"
                ),
                "audio_calls": "CommsCore.AudioCalls.AudioCall",
            },
        )

        declared_children = set()
        for path in sorted(
            (root / "apps/comms_core/lib/comms_core/audio_calls").rglob("*.ex")
        ):
            declared_children.update(
                core_module_declarations(path.read_text(encoding="utf-8"))
            )
        self.assertEqual(declared_children, public_contracts | internal_modules)
        self.assertTrue(
            (root / "apps/comms_core/lib/comms_core/audio_calls.ex").is_file()
        )

        collaborations = {
            declaration["id"]: declaration
            for declaration in manifest["runtime_collaborations"]
        }
        self.assertEqual(
            set(collaborations),
            {
                "conversation-call-lifecycle",
                "identity-call-lifecycle",
                "identity-initial-conversation-bootstrap",
                "identity-notification-lifecycle",
                "tenant-authorization-actor",
                "tenant-call-lifecycle",
                "tenant-identity-access",
                "tenant-invitation-identity",
            },
        )
        expected_call_collaborations = {
            "identity-call-lifecycle": {
                "consumer": "identity_access",
                "port": "CommsCore.Accounts.CallLifecyclePort",
                "result_contract": "CommsCore.Accounts.CallLifecycleReceipt",
                "callers": [
                    "CommsCore.Accounts",
                    "CommsCore.Accounts.PasswordRecovery",
                ],
                "operations": [{"name": "revoke_identity_access", "arity": 1}],
                "binding_key": "identity_call_lifecycle_adapter",
            },
            "tenant-call-lifecycle": {
                "consumer": "tenant_administration",
                "port": "CommsCore.Administration.CallLifecyclePort",
                "result_contract": ("CommsCore.Administration.CallLifecycleReceipt"),
                "callers": ["CommsCore.Administration"],
                "operations": [{"name": "revoke_tenant_media", "arity": 1}],
                "binding_key": "tenant_call_lifecycle_adapter",
            },
            "conversation-call-lifecycle": {
                "consumer": "conversations",
                "port": "CommsCore.Conversations.CallLifecyclePort",
                "result_contract": ("CommsCore.Conversations.CallLifecycleReceipt"),
                "callers": ["CommsCore.Conversations"],
                "operations": [{"name": "revoke_conversation_access", "arity": 1}],
                "binding_key": "conversation_call_lifecycle_adapter",
            },
        }
        for collaboration_id, expected in expected_call_collaborations.items():
            with self.subTest(collaboration=collaboration_id):
                declaration = collaborations[collaboration_id]
                self.assertEqual(
                    set(declaration),
                    {
                        "id",
                        "consumer",
                        "provider",
                        "port",
                        "result_contract",
                        "implementation",
                        "callers",
                        "operations",
                        "binding",
                        "transaction",
                        "graph_semantics",
                        "condition",
                    },
                )
                self.assertEqual(declaration["consumer"], expected["consumer"])
                self.assertEqual(declaration["provider"], "calls")
                self.assertEqual(declaration["port"], expected["port"])
                self.assertEqual(
                    declaration["result_contract"],
                    expected["result_contract"],
                )
                self.assertEqual(declaration["implementation"], "CommsCore.AudioCalls")
                self.assertEqual(declaration["callers"], expected["callers"])
                self.assertEqual(declaration["operations"], expected["operations"])
                self.assertEqual(
                    declaration["binding"],
                    {
                        "application": "comms_core",
                        "key": expected["binding_key"],
                        "module": "CommsCore.AudioCalls",
                    },
                )
                self.assertEqual(declaration["transaction"], "required")
                self.assertEqual(
                    declaration["graph_semantics"],
                    {
                        "control_flow": f"{expected['consumer']}_to_calls",
                        "compile_dependency": f"calls_to_{expected['consumer']}",
                        "static_cycle_policy": "dependency_inversion",
                    },
                )
                self.assertIsInstance(declaration["condition"], str)
                self.assertTrue(declaration["condition"].strip())

    def test_repository_inverts_identity_notification_lifecycle_dependency(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        identity = manifest["contexts"]["identity_access"]
        identity_notification_contracts = {
            "CommsCore.Accounts.NotificationCommand",
            "CommsCore.Accounts.NotificationPort",
            "CommsCore.Accounts.NotificationReceipt",
        }

        self.assertNotIn("notification_delivery", identity["allowed_dependencies"])
        self.assertTrue(
            identity_notification_contracts.issubset(set(identity["public_contracts"]))
        )

        identity_to_notification_edges = [
            (item.path, item.detail)
            for item in analyze_context_boundaries(root, manifest)
            if item.rule == "undeclared_context_edge"
            and item.detail.startswith("identity_access -> notification_delivery ")
        ]
        self.assertEqual(identity_to_notification_edges, [])

        for relative_path in (
            "apps/comms_core/lib/comms_core/accounts.ex",
            "apps/comms_core/lib/comms_core/accounts/password_recovery.ex",
            "apps/comms_core/lib/comms_core/password_recovery.ex",
        ):
            with self.subTest(path=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                self.assertNotIn("CommsCore.Notifications", source)
                self.assertNotIn("IntentView", source)

        config_bindings = []
        for path in sorted((root / "config").rglob("*.exs")):
            source = path.read_text(encoding="utf-8")
            config_bindings.extend(
                path.relative_to(root).as_posix()
                for _ in range(source.count("identity_notification_adapter:"))
            )
        self.assertEqual(config_bindings, ["config/config.exs"])

        config_source = (root / "config/config.exs").read_text(encoding="utf-8")
        self.assertIn(
            "identity_notification_adapter: CommsCore.Notifications",
            config_source,
        )

        notifications_source = (
            root / "apps/comms_core/lib/comms_core/notifications.ex"
        ).read_text(encoding="utf-8")
        notifications_references = core_module_references(notifications_source)
        self.assertRegex(
            notifications_source,
            r"@behaviour\s+(?:CommsCore\.Accounts\.)?NotificationPort\b",
        )
        self.assertIn("def execute(%NotificationCommand", notifications_source)
        self.assertIn("%NotificationReceipt{", notifications_source)
        self.assertTrue(
            identity_notification_contracts.issubset(notifications_references),
            notifications_references,
        )
        self.assertTrue(
            {
                "CommsCore.Accounts.PasswordRecovery",
                "CommsCore.PasswordRecovery",
                "CommsCore.PasswordRecovery.Request",
            }.isdisjoint(notifications_references),
            notifications_references,
        )
        self.assertNotIn("def disable_push_for_device(", notifications_source)
        self.assertNotIn("def disable_push_for_user(", notifications_source)

        port_reference_paths = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            references = core_module_references(path.read_text(encoding="utf-8"))
            if "CommsCore.Accounts.NotificationPort" in references:
                port_reference_paths.append(path.relative_to(root).as_posix())
        self.assertEqual(
            port_reference_paths,
            [
                "apps/comms_core/lib/comms_core/accounts/notification_port.ex",
                "apps/comms_core/lib/comms_core/accounts/password_recovery.ex",
                "apps/comms_core/lib/comms_core/accounts.ex",
                "apps/comms_core/lib/comms_core/notifications.ex",
            ],
        )

        port_callers = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            if "NotificationPort.execute" in path.read_text(encoding="utf-8"):
                port_callers.append(path.relative_to(root).as_posix())
        self.assertEqual(
            port_callers,
            [
                "apps/comms_core/lib/comms_core/accounts/password_recovery.ex",
                "apps/comms_core/lib/comms_core/accounts.ex",
            ],
        )

        adapter_contract_leaks = []
        for app in ("comms_web", "comms_workers", "comms_integrations"):
            for path in sorted((root / f"apps/{app}/lib").rglob("*.ex")):
                references = core_module_references(path.read_text(encoding="utf-8"))
                leaked = sorted(
                    references.intersection(identity_notification_contracts)
                )
                if leaked:
                    adapter_contract_leaks.append(
                        (path.relative_to(root).as_posix(), leaked)
                    )
        self.assertEqual(adapter_contract_leaks, [])

    def test_repository_inverts_identity_conversation_workflows(self) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        identity = manifest["contexts"]["identity_access"]
        conversations = manifest["contexts"]["conversations"]
        bootstrap_contracts = {
            "CommsCore.Accounts.ConversationBootstrapPort",
            "CommsCore.Accounts.InitialConversationCommand",
            "CommsCore.Accounts.InitialConversationReceipt",
        }

        self.assertNotIn("conversations", identity["allowed_dependencies"])
        self.assertIn("identity_access", conversations["allowed_dependencies"])
        self.assertTrue(bootstrap_contracts.issubset(set(identity["public_contracts"])))

        collaborations = {
            item["id"]: item for item in manifest["runtime_collaborations"]
        }
        self.assertEqual(
            set(collaborations),
            {
                "conversation-call-lifecycle",
                "identity-call-lifecycle",
                "identity-initial-conversation-bootstrap",
                "identity-notification-lifecycle",
                "tenant-authorization-actor",
                "tenant-call-lifecycle",
                "tenant-identity-access",
                "tenant-invitation-identity",
            },
        )
        self.assertEqual(
            collaborations["tenant-identity-access"]["transaction"],
            "independent",
        )
        self.assertEqual(
            collaborations["tenant-authorization-actor"]["transaction"],
            "independent",
        )
        self.assertEqual(
            collaborations["tenant-invitation-identity"]["transaction"],
            "required",
        )
        self.assertEqual(
            collaborations["identity-initial-conversation-bootstrap"],
            {
                "id": "identity-initial-conversation-bootstrap",
                "consumer": "identity_access",
                "provider": "conversations",
                "port": "CommsCore.Accounts.ConversationBootstrapPort",
                "result_contract": "CommsCore.Accounts.InitialConversationReceipt",
                "implementation": "CommsCore.Conversations",
                "callers": ["CommsCore.Accounts"],
                "operations": [
                    {"name": "create_initial_channel", "arity": 1},
                    {"name": "fetch_initial_channel", "arity": 2},
                ],
                "binding": {
                    "application": "comms_core",
                    "key": "identity_conversation_bootstrap_adapter",
                    "module": "CommsCore.Conversations",
                },
                "transaction": "required",
                "graph_semantics": {
                    "control_flow": "identity_access_to_conversations",
                    "compile_dependency": "conversations_to_identity_access",
                    "static_cycle_policy": "dependency_inversion",
                },
                "condition": (
                    "IdentityAccess owns the narrow bootstrap command/result "
                    "contract while Conversations implements and persists its "
                    "owner contribution on the caller transaction; this reviewed "
                    "runtime collaboration is reported separately from compiled "
                    "context edges and may not grow beyond the declared operations "
                    "or caller."
                ),
            },
        )

        violations = analyze_context_boundaries(root, manifest)
        identity_to_conversations = [
            (item.path, item.detail)
            for item in violations
            if item.rule == "undeclared_context_edge"
            and item.detail.startswith("identity_access -> conversations ")
        ]
        self.assertEqual(identity_to_conversations, [])

        for relative_path in (
            "apps/comms_core/lib/comms_core/accounts.ex",
            "apps/comms_core/lib/comms_core/service_accounts.ex",
        ):
            with self.subTest(path=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                references = core_module_references(source)
                self.assertFalse(
                    any(
                        module == "CommsCore.Conversations"
                        or module.startswith("CommsCore.Conversations.")
                        for module in references
                    ),
                    references,
                )
                self.assertNotIn('"conversations"', source)
                self.assertNotIn('"conversation_memberships"', source)

        config_bindings = []
        for path in sorted((root / "config").rglob("*.exs")):
            source = path.read_text(encoding="utf-8")
            config_bindings.extend(
                path.relative_to(root).as_posix()
                for _ in range(
                    len(
                        re.findall(
                            r"\bidentity_conversation_bootstrap_adapter\b",
                            source,
                        )
                    )
                )
            )
        self.assertEqual(config_bindings, ["config/config.exs"])

        config_source = (root / "config/config.exs").read_text(encoding="utf-8")
        self.assertIn(
            "identity_conversation_bootstrap_adapter: CommsCore.Conversations",
            config_source,
        )

        production_binding_overrides = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            source = path.read_text(encoding="utf-8")
            if re.search(
                r"Application\.(?:put_env|delete_env)\s*\([^)]*"
                r"identity_conversation_bootstrap_adapter",
                source,
                re.DOTALL,
            ):
                production_binding_overrides.append(path.relative_to(root).as_posix())
        self.assertEqual(production_binding_overrides, [])

        port_source = (
            root / "apps/comms_core/lib/comms_core/accounts/"
            "conversation_bootstrap_port.ex"
        ).read_text(encoding="utf-8")
        self.assertEqual(
            set(re.findall(r"@callback\s+([a-z_][a-z0-9_]*)\s*\(", port_source)),
            {"create_initial_channel", "fetch_initial_channel"},
        )

        conversations_source = (
            root / "apps/comms_core/lib/comms_core/conversations.ex"
        ).read_text(encoding="utf-8")
        self.assertRegex(
            conversations_source,
            r"@behaviour\s+(?:CommsCore\.Accounts\.)?ConversationBootstrapPort\b",
        )
        for owner_api in (
            "def create_initial_channel(",
            "def fetch_initial_channel(",
            "def list_for_service(",
            "def authorize_service_access(",
        ):
            self.assertIn(owner_api, conversations_source)
        self.assertIn(
            'ServiceAccounts.authorize_service(subject, "conversations:read")',
            conversations_source,
        )
        self.assertIn("from(membership in Membership", conversations_source)

        public_contract_owners = {}
        for context_name, context in manifest["contexts"].items():
            for contract in context.get("public_contracts", []):
                public_contract_owners.setdefault(contract, []).append(context_name)
        self.assertEqual(
            {
                contract: owners
                for contract, owners in public_contract_owners.items()
                if len(owners) != 1
            },
            {},
        )

        port_reference_paths = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            references = core_module_references(path.read_text(encoding="utf-8"))
            if "CommsCore.Accounts.ConversationBootstrapPort" in references:
                port_reference_paths.append(path.relative_to(root).as_posix())
        self.assertEqual(
            port_reference_paths,
            [
                "apps/comms_core/lib/comms_core/accounts/conversation_bootstrap_port.ex",
                "apps/comms_core/lib/comms_core/accounts.ex",
                "apps/comms_core/lib/comms_core/conversations.ex",
            ],
        )

        bootstrap_port_callers = []
        bootstrap_calls = (
            "ConversationBootstrapPort.append_initial_channel(",
            "ConversationBootstrapPort.create_initial_channel(",
            "ConversationBootstrapPort.fetch_initial_channel(",
        )
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            source = path.read_text(encoding="utf-8")
            if any(call in source for call in bootstrap_calls):
                bootstrap_port_callers.append(path.relative_to(root).as_posix())
        self.assertEqual(
            bootstrap_port_callers,
            ["apps/comms_core/lib/comms_core/accounts.ex"],
        )

        service_accounts_source = (
            root / "apps/comms_core/lib/comms_core/service_accounts.ex"
        ).read_text(encoding="utf-8")
        self.assertNotIn("def list_conversations(", service_accounts_source)
        self.assertNotIn(
            "def authorize_service(subject, required_scope,",
            service_accounts_source,
        )
        self.assertNotIn("maybe_authorize_membership", service_accounts_source)

        messaging_source = (
            root / "apps/comms_core/lib/comms_core/messaging.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("Conversations.authorize_service_access(", messaging_source)
        self.assertNotIn(
            'ServiceAccounts.authorize_service(subject, "messages:',
            messaging_source,
        )

        controller_source = (
            root / "apps/comms_web/lib/comms_web/controllers/"
            "service_conversation_controller.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("Conversations.list_for_service(", controller_source)
        self.assertNotIn("CommsCore.ServiceAccounts", controller_source)

        owner_api_callers = {
            "Conversations.authorize_service_access(": [],
            "Conversations.list_for_service(": [],
            "ServiceAccounts.authorize_service(": [],
        }
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            source = path.read_text(encoding="utf-8")
            for call in owner_api_callers:
                if call in source:
                    owner_api_callers[call].append(path.relative_to(root).as_posix())
        self.assertEqual(
            owner_api_callers,
            {
                "Conversations.authorize_service_access(": [
                    "apps/comms_core/lib/comms_core/messaging.ex"
                ],
                "Conversations.list_for_service(": [
                    "apps/comms_web/lib/comms_web/controllers/"
                    "service_conversation_controller.ex"
                ],
                "ServiceAccounts.authorize_service(": [
                    "apps/comms_core/lib/comms_core/conversations.ex",
                    "apps/comms_core/lib/comms_core/messaging.ex",
                ],
            },
        )

        released_adapter_contract_leaks = []
        internal_bootstrap_contracts = bootstrap_contracts - {
            "CommsCore.Accounts.InitialConversationReceipt"
        }
        for app in ("comms_web", "comms_workers", "comms_integrations"):
            for path in sorted((root / f"apps/{app}/lib").rglob("*.ex")):
                references = core_module_references(path.read_text(encoding="utf-8"))
                leaked = sorted(references.intersection(internal_bootstrap_contracts))
                if leaked:
                    released_adapter_contract_leaks.append(
                        (path.relative_to(root).as_posix(), leaked)
                    )
        self.assertEqual(released_adapter_contract_leaks, [])

        receipt_adapter_callers = []
        for app in ("comms_web", "comms_workers", "comms_integrations"):
            for path in sorted((root / f"apps/{app}/lib").rglob("*.ex")):
                references = core_module_references(path.read_text(encoding="utf-8"))
                if "CommsCore.Accounts.InitialConversationReceipt" in references:
                    receipt_adapter_callers.append(path.relative_to(root).as_posix())
        self.assertEqual(
            receipt_adapter_callers,
            ["apps/comms_web/lib/comms_web/presenter.ex"],
        )

        current_fingerprints = {item.fingerprint for item in violations}
        removed_fingerprints = {
            "127209a1d6c0c922",
            "4f44767efee5184f",
            "20f498850eb580eb",
            "3c6d68b4f4a50a0d",
            "de5e0182434764c8",
        }
        self.assertTrue(removed_fingerprints.isdisjoint(current_fingerprints))

        self.assertEqual(
            [
                item.render()
                for item in violations
                if item.rule
                in {
                    "business_context_cycle",
                    "runtime_context_cycle",
                }
            ],
            [],
        )

    def test_repository_retires_authorization_namespace_and_binding(self) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        self.assertNotIn("authorization_kernel", manifest["contexts"])
        self.assertIn("CommsCore.Authorization", manifest["retired_modules"])
        self.assertIn(
            {
                "application": "comms_core",
                "key": "authorization_adapter",
            },
            manifest["retired_runtime_bindings"],
        )

        for relative_path in (
            "apps/comms_core/lib/comms_core/authorization.ex",
            "apps/comms_core/lib/comms_core/authorization/database.ex",
            "apps/comms_core/lib/comms_core/authorization/deny_all.ex",
            "apps/comms_core/lib/comms_core/authorization/policy.ex",
        ):
            with self.subTest(path=relative_path):
                self.assertFalse((root / relative_path).exists())

        leaked_modules = []
        leaked_bindings = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            source = path.read_text(encoding="utf-8")
            modules = set(core_module_declarations(source)) | set(
                core_module_references(source)
            )
            if any(
                module == "CommsCore.Authorization"
                or module.startswith("CommsCore.Authorization.")
                for module in modules
            ):
                leaked_modules.append(path.relative_to(root).as_posix())
            if "authorization_adapter" in source:
                leaked_bindings.append(path.relative_to(root).as_posix())
        for path in sorted((root / "config").rglob("*.exs")):
            source = path.read_text(encoding="utf-8")
            if any(
                module == "CommsCore.Authorization"
                or module.startswith("CommsCore.Authorization.")
                for module in core_module_references(source)
            ):
                leaked_modules.append(path.relative_to(root).as_posix())
            if "authorization_adapter" in source:
                leaked_bindings.append(path.relative_to(root).as_posix())
        self.assertEqual(leaked_modules, [])
        self.assertEqual(leaked_bindings, [])

        graphs = context_graphs(root, manifest)
        self.assertEqual(
            context_cycle_violations(graphs.compiled, "business_context_cycle"),
            [],
        )
        self.assertEqual(
            context_cycle_violations(graphs.runtime, "runtime_context_cycle"),
            [],
        )

    def test_repository_owns_conversation_admission_queries_and_composes_usage_as_read_model(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        tenant = manifest["contexts"]["tenant_administration"]
        conversations = manifest["contexts"]["conversations"]
        operations = manifest["contexts"]["operations_read_model"]

        self.assertNotIn("conversations", tenant["allowed_dependencies"])
        self.assertIn("tenant_administration", conversations["allowed_dependencies"])
        self.assertIn(
            "CommsCore.Administration.AdmissionPolicy",
            tenant["public_contracts"],
        )
        self.assertIn(
            "CommsCore.Conversations.AdmissionUsage",
            conversations["public_contracts"],
        )
        self.assertTrue(
            {"tenant_administration", "conversations"}.issubset(
                set(operations["allowed_dependencies"])
            )
        )
        self.assertEqual(
            operations["public_contracts"],
            ["CommsCore.Operations.TenantQuotaUsage"],
        )

        read_model = next(
            item
            for item in manifest["read_model_exceptions"]
            if item["id"] == "operations-cross-context-read-model"
        )
        self.assertEqual(
            read_model["owners"],
            [
                "identity_access",
                "tenant_administration",
                "conversations",
                "conversation_content",
                "notification_delivery",
                "webhook_management",
                "platform_eventing",
                "platform_persistence",
            ],
        )
        self.assertEqual(
            read_model["access"]["public_contracts"],
            [
                "CommsCore.Administration.AdmissionPolicy",
                "CommsCore.Conversations.AdmissionUsage",
            ],
        )
        self.assertEqual(
            read_model["access"]["public_queries"],
            [
                "CommsCore.AdmissionQuotas.admission_policy/1",
                "CommsCore.Administration.authorize_administer_tenant/1",
                "CommsCore.Accounts.active_user_count/1",
                "CommsCore.Accounts.authorize_view_platform_operations/1",
                "CommsCore.Conversations.admission_usage/1",
            ],
        )
        self.assertEqual(
            read_model["access"]["source_tables"],
            [
                "attachments",
                "notification_intents",
                "webhook_deliveries",
                "oban_jobs",
                "outbox_events",
            ],
        )

        quota_source = (
            root / "apps/comms_core/lib/comms_core/admission_quotas.ex"
        ).read_text(encoding="utf-8")
        quota_references = core_module_references(quota_source)
        self.assertTrue(
            {
                "CommsCore.Conversations",
                "CommsCore.Conversations.Conversation",
                "CommsCore.Conversations.Membership",
            }.isdisjoint(quota_references),
            quota_references,
        )
        self.assertNotIn("FROM conversations", quota_source)
        self.assertNotIn("conversation_memberships", quota_source)
        self.assertNotIn("def ensure_conversation_creation(", quota_source)
        self.assertNotIn("def ensure_conversation_member_capacity(", quota_source)
        self.assertIn("def check_conversation_creation(", quota_source)
        self.assertIn("def check_conversation_member_capacity(", quota_source)

        conversation_source = (
            root / "apps/comms_core/lib/comms_core/conversations.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("def admission_usage(", conversation_source)
        self.assertIn("defp active_conversation_count(", conversation_source)
        self.assertIn(
            "defp ensure_conversation_member_capacity(",
            conversation_source,
        )
        self.assertIn("AdmissionQuotas.locked_policy(", conversation_source)

        def public_function_section(signature: str) -> str:
            start = conversation_source.index(signature)
            end = conversation_source.find("\n  def ", start + len(signature))
            return (
                conversation_source[start:]
                if end == -1
                else conversation_source[start:end]
            )

        for signature, lock_marker, count_marker in (
            (
                "\n  def create(attrs, subject)",
                "policy = admission_policy!(tenant_id)",
                "current_active_conversations = active_conversation_count(tenant_id)",
            ),
            (
                "\n  def join_public_channel(id, subject)",
                "policy = admission_policy!(conversation.tenant_id)",
                "ensure_conversation_member_capacity(policy, conversation)",
            ),
            (
                "\n  def add_member(conversation_id, user_id, role, subject)",
                "policy = admission_policy!(conversation.tenant_id)",
                "ensure_conversation_member_capacity(policy, conversation)",
            ),
        ):
            with self.subTest(signature=signature):
                section = public_function_section(signature)
                self.assertLess(section.index(lock_marker), section.index(count_marker))

        operations_source = (
            root / "apps/comms_core/lib/comms_core/operations.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("def tenant_admission_usage(", operations_source)
        self.assertIn("Accounts.active_user_count(", operations_source)
        self.assertIn("AdmissionQuotas.admission_policy(", operations_source)
        self.assertIn("Conversations.admission_usage(", operations_source)

        projection_callers = {
            "Accounts.active_user_count(": [],
            "AdmissionQuotas.admission_policy(": [],
            "Conversations.admission_usage(": [],
        }
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            source = path.read_text(encoding="utf-8")
            for call in projection_callers:
                if call in source:
                    projection_callers[call].append(path.relative_to(root).as_posix())
        self.assertEqual(
            projection_callers,
            {
                "Accounts.active_user_count(": [
                    "apps/comms_core/lib/comms_core/operations.ex"
                ],
                "AdmissionQuotas.admission_policy(": [
                    "apps/comms_core/lib/comms_core/operations.ex"
                ],
                "Conversations.admission_usage(": [
                    "apps/comms_core/lib/comms_core/operations.ex"
                ],
            },
        )

        core_operations_callers = []
        for path in sorted((root / "apps/comms_core/lib").rglob("*.ex")):
            if path.name == "operations.ex":
                continue
            if "CommsCore.Operations" in core_module_references(
                path.read_text(encoding="utf-8")
            ):
                core_operations_callers.append(path.relative_to(root).as_posix())
        self.assertEqual(core_operations_callers, [])

        controller_source = (
            root / "apps/comms_web/lib/comms_web/controllers/admin_tenant_controller.ex"
        ).read_text(encoding="utf-8")
        self.assertIn("Operations.tenant_admission_usage(", controller_source)

        violations = analyze_context_boundaries(root, manifest)
        tenant_to_conversations = [
            item.render()
            for item in violations
            if item.rule == "undeclared_context_edge"
            and item.detail.startswith("tenant_administration -> conversations ")
        ]
        self.assertEqual(tenant_to_conversations, [])
        self.assertFalse(
            any(item.rule == "read_model_reverse_dependency" for item in violations),
            [item.render() for item in violations],
        )

    def test_repository_keeps_released_adapters_on_declared_public_contracts(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")

        expected_contracts = {
            "identity_access": {
                "CommsCore.Accounts.AccessContext",
                "CommsCore.Accounts.AuthenticationResult",
                "CommsCore.Accounts.DeviceView",
                "CommsCore.Accounts.SessionView",
                "CommsCore.Accounts.UserView",
                "CommsCore.ServiceAccounts.ServiceAccountView",
            },
            "tenant_administration": {
                "CommsCore.Administration.InvitationView",
                "CommsCore.Administration.TenantSettingsView",
                "CommsCore.Administration.TenantView",
            },
            "conversations": {
                "CommsCore.Conversations.ConversationView",
                "CommsCore.Conversations.MembershipView",
            },
            "calls": {
                "CommsCore.AudioCalls.CallView",
                "CommsCore.AudioCalls.CredentialRequest",
                "CommsCore.AudioCalls.EvictionClaim",
                "CommsCore.AudioCalls.EvictionProgress",
                "CommsCore.AudioCalls.ProviderCall",
            },
            "webhook_management": {
                "CommsCore.Integrations.WebhookDeliveryClaim",
                "CommsCore.Integrations.WebhookDeliveryView",
                "CommsCore.Integrations.WebhookDispatchRequest",
                "CommsCore.Integrations.WebhookEndpointView",
            },
            "trust_governance": {
                "CommsCore.Governance.DeletionExecution",
                "CommsCore.Governance.DeletionRequestView",
                "CommsCore.Governance.LegalHoldView",
                "CommsCore.Governance.RetentionPolicyView",
                "CommsCore.Moderation.ActionView",
                "CommsCore.Moderation.CaseView",
            },
            "platform_eventing": {"CommsCore.Outbox.Event"},
        }

        for context, contracts in expected_contracts.items():
            self.assertTrue(
                contracts.issubset(
                    set(manifest["contexts"][context]["public_contracts"])
                )
            )

        violations = analyze_context_boundaries(root, manifest)
        self.assertEqual(
            [
                item.rule
                for item in violations
                if item.rule.startswith("public_contract_")
            ],
            [],
        )
        self.assertEqual(
            [
                item.detail
                for item in violations
                if item.rule == "adapter_schema_import"
            ],
            [],
        )
        self.assertEqual(
            [item for item in violations if item.rule == "adapter_changeset_import"],
            [],
        )

    def test_rejects_adapter_imports_of_ecto_schemas(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex"
            )
            adapter = root / "apps/comms_web/lib/comms_web/presenter.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text("alias CommsCore.Alpha.Record\n", encoding="utf-8")

            self.assert_rule(root, "adapter_schema_import")

    def test_resolves_prefix_aliases_for_core_and_adapter_schema_leaks(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            core = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            core.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta, as: B\n"
                "  def read, do: %B.Record{}\n"
                "end\n",
                encoding="utf-8",
            )
            adapter = root / "apps/comms_web/lib/comms_web/presenter.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text(
                "defmodule CommsWeb.Presenter do\n"
                "  alias CommsCore, as: Core\n"
                "  def render, do: %Core.Alpha.Record{}\n"
                "end\n",
                encoding="utf-8",
            )

            observed = {
                item.rule
                for item in analyze_context_boundaries(
                    root,
                    read_yaml(root / "docs/02-architecture/context-boundaries.yaml"),
                )
            }
            self.assertIn("foreign_schema_import", observed)
            self.assertIn("undeclared_context_edge", observed)
            self.assertIn("adapter_schema_import", observed)

    def test_rejects_adapter_changeset_dependencies(self) -> None:
        with self.boundary_fixture() as root:
            adapter = root / "apps/comms_web/lib/comms_web/fallback_controller.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text(
                "def call(conn, {:error, %Ecto.Changeset{} = changeset}), "
                "do: Ecto.Changeset.traverse_errors(changeset, & &1)\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "adapter_changeset_import")

    def test_rejects_adapter_changeset_through_prefix_alias(self) -> None:
        with self.boundary_fixture() as root:
            adapter = root / "apps/comms_web/lib/comms_web/fallback_controller.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text(
                "defmodule CommsWeb.FallbackController do\n"
                "  alias Ecto, as: ORM\n"
                "  def call(%ORM.Changeset{} = changeset), do: changeset\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "adapter_changeset_import")

    def test_rejects_public_contracts_that_are_ecto_schemas(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex"
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["public_contracts"] = [
                "CommsCore.Alpha.Record"
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )

            self.assert_rule(root, "public_contract_is_schema")

    def test_discovers_parenthesized_and_attribute_schema_sources(self) -> None:
        variants = (
            'schema("alpha_records") do',
            '@source "alpha_records"\n  schema @source do',
        )
        for schema_declaration in variants:
            with (
                self.subTest(schema_declaration=schema_declaration),
                self.boundary_fixture() as root,
            ):
                schema = root / "apps/comms_core/lib/comms_core/alpha/record.ex"
                schema.parent.mkdir(parents=True, exist_ok=True)
                schema.write_text(
                    "  defmodule(Elixir.CommsCore.Alpha.Record) do\n"
                    f"  {schema_declaration}\n"
                    "  end\n"
                    "end\n",
                    encoding="utf-8",
                )

                manifest = read_yaml(
                    root / "docs/02-architecture/context-boundaries.yaml"
                )
                violations = analyze_context_boundaries(root, manifest)
                self.assertNotIn(
                    "canonical_schema_missing",
                    {item.rule for item in violations},
                    violations,
                )
                self.assertNotIn(
                    "invalid_table_declaration",
                    {item.rule for item in violations},
                    violations,
                )

    def test_rejects_unresolved_schema_macro_source(self) -> None:
        with self.boundary_fixture() as root:
            schema = root / "apps/comms_core/lib/comms_core/alpha/record.ex"
            schema.parent.mkdir(parents=True, exist_ok=True)
            schema.write_text(
                "defmodule CommsCore.Alpha.Record do\n"
                "  @source source_from_runtime()\n"
                "  schema @source do\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "invalid_table_declaration")

    def test_rejects_missing_declared_public_contracts(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["public_contracts"] = [
                "CommsCore.Alpha.MissingView"
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )

            self.assert_rule(root, "public_contract_missing")

    def test_rejects_missing_or_schema_backed_public_facades(self) -> None:
        variants = (
            ("CommsCore.Alpha.Missing", "public_facade_missing"),
            ("CommsCore.Alpha.Record", "public_facade_is_schema"),
        )
        for facade, expected_rule in variants:
            with (
                self.subTest(facade=facade),
                self.boundary_fixture() as root,
            ):
                self.write_schema(
                    root,
                    "CommsCore.Alpha.Record",
                    "alpha_records",
                    "alpha/record.ex",
                )
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["contexts"]["alpha"]["public_facades"] = [facade]
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )

                self.assert_rule(root, expected_rule)

    def test_rejects_schema_exposure_from_every_public_contract_type_surface(
        self,
    ) -> None:
        variants = (
            (
                "callback",
                "  @callback load() :: CommsCore.Alpha.Record.t()\n",
            ),
            (
                "aliased_type_struct",
                "  alias CommsCore.Alpha.Record\n  @type t :: %Record{}\n",
            ),
            (
                "macrocallback_struct",
                "  @macrocallback build() :: %CommsCore.Alpha.Record{}\n",
            ),
        )
        for label, declaration in variants:
            with (
                self.subTest(surface=label),
                self.boundary_fixture() as root,
            ):
                self.write_schema(
                    root,
                    "CommsCore.Alpha.Record",
                    "alpha_records",
                    "alpha/record.ex",
                )
                contract = root / "apps/comms_core/lib/comms_core/alpha/port.ex"
                contract.parent.mkdir(parents=True, exist_ok=True)
                contract.write_text(
                    f"defmodule CommsCore.Alpha.Port do\n{declaration}end\n",
                    encoding="utf-8",
                )
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["contexts"]["alpha"]["public_contracts"] = [
                    "CommsCore.Alpha.Port"
                ]
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )

                self.assert_rule(root, "public_ecto_contract")

    def test_rejects_undeclared_context_edges_and_foreign_writes(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.Record\n"
                "  def change(attrs) do\n"
                "    Ecto.Multi.new()\n"
                "    |> Ecto.Multi.insert(:record, Record.changeset(%Record{}, attrs))\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "undeclared_context_edge")
            self.assert_rule(root, "direct_foreign_write")

    def test_resolves_prefix_schema_alias_in_direct_foreign_write(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            source = root / "apps/comms_core/lib/comms_core/alpha/writer.ex"
            source.write_text(
                "defmodule CommsCore.Alpha.Writer do\n"
                "  alias CommsCore.Beta, as: B\n"
                "  alias CommsCore.Repo, as: R\n"
                "  def write, do: R.insert(%B.Record{})\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "direct_foreign_write")

    def test_resolves_tracked_repo_bindings_in_direct_foreign_write(self) -> None:
        writes = (
            (
                "  alias CommsCore.Repo\n"
                "  def write do\n"
                "    repo = Repo\n"
                "    repo.insert(%B.Record{})\n"
                "  end\n"
            ),
            (
                "  alias CommsCore.Repo\n"
                "  @repo Repo\n"
                "  def write, do: @repo.insert(%B.Record{})\n"
            ),
        )
        for write_body in writes:
            with (
                self.subTest(write_body=write_body),
                self.boundary_fixture() as root,
            ):
                self.write_schema(
                    root,
                    "CommsCore.Alpha.Record",
                    "alpha_records",
                    "alpha/record.ex",
                )
                self.write_schema(
                    root,
                    "CommsCore.Beta.Record",
                    "beta_records",
                    "beta/record.ex",
                )
                source = root / "apps/comms_core/lib/comms_core/alpha/writer.ex"
                source.write_text(
                    "defmodule CommsCore.Alpha.Writer do\n"
                    "  alias CommsCore.Beta, as: B\n"
                    f"{write_body}"
                    "end\n",
                    encoding="utf-8",
                )

                self.assert_rule(root, "direct_foreign_write")

    def test_does_not_treat_foreign_reads_plus_owner_writes_as_foreign_writes(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Record\n"
                "  alias CommsCore.Beta.Record, as: BetaRecord\n"
                "  alias CommsCore.Repo\n"
                "  def read_then_write(attrs) do\n"
                "    _foreign = Repo.all(BetaRecord)\n"
                "    %Record{} |> Record.changeset(attrs) |> Repo.insert()\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_not_rule(root, "direct_foreign_write")

    def test_attributes_canonical_schema_ownership_from_the_table_manifest(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Alpha.Tenant", "tenants", "alpha/tenant.ex"
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["tables"]["tenants"] = {
                "owner": "beta",
                "canonical_schema": "CommsCore.Alpha.Tenant",
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )

            owner_source = root / "apps/comms_core/lib/comms_core/beta/admin.ex"
            owner_source.parent.mkdir(parents=True, exist_ok=True)
            owner_source.write_text(
                "defmodule CommsCore.Beta.Admin do\n"
                "  alias CommsCore.Alpha.Tenant\n"
                "  alias CommsCore.Repo\n"
                "  def change(attrs), do: Tenant.changeset(%Tenant{}, attrs) |> Repo.insert()\n"
                "end\n",
                encoding="utf-8",
            )
            self.assert_not_rule(root, "direct_foreign_write")

            foreign_source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            foreign_source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Tenant\n"
                "  alias CommsCore.Repo\n"
                "  def change(attrs), do: Tenant.changeset(%Tenant{}, attrs) |> Repo.insert()\n"
                "end\n",
                encoding="utf-8",
            )
            self.assert_rule(root, "direct_foreign_write")

    def test_attributes_schema_reads_and_edges_to_the_declared_table_owner(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Tenant",
                "tenants",
                "alpha/tenant.ex",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["tables"]["tenants"] = {
                "owner": "beta",
                "canonical_schema": "CommsCore.Alpha.Tenant",
                "access": "owner_only",
                "access_namespaces": ["CommsCore.Beta"],
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Alpha.Tenant\n"
                "  def id(%Tenant{id: id}), do: id\n"
                "end\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertTrue(
                any(
                    item.rule == "foreign_schema_import"
                    and "CommsCore.Alpha.Tenant" in item.detail
                    for item in violations
                ),
                [item.render() for item in violations],
            )
            self.assertTrue(
                any(
                    item.rule == "undeclared_context_edge"
                    and item.path.endswith("alpha/reader.ex")
                    and "alpha -> beta" in item.detail
                    for item in violations
                ),
                [item.render() for item in violations],
            )

    def test_does_not_treat_an_unpersisted_foreign_changeset_as_a_write(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Record\n"
                "  alias CommsCore.Beta.Record, as: BetaRecord\n"
                "  alias CommsCore.Repo\n"
                "  def change(attrs) do\n"
                "    _unused = BetaRecord.changeset(%BetaRecord{}, attrs)\n"
                "    Record.changeset(%Record{}, attrs) |> Repo.insert()\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_not_rule(root, "direct_foreign_write")

    def test_rejects_direct_and_query_variable_foreign_bulk_writes(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  import Ecto.Query\n"
                "  alias CommsCore.Beta.Record\n"
                "  alias CommsCore.Repo\n"
                "  def direct, do: Repo.delete_all(from(record in Record))\n"
                "  def through_variable do\n"
                '    query = from(record in Record, where: record.id == ^"id")\n'
                "    Repo.update_all(query, set: [status: :deleted])\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "direct_foreign_write")

    def test_attributes_only_the_root_of_a_joined_bulk_write(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  import Ecto.Query\n"
                "  alias CommsCore.Alpha.Record\n"
                "  alias CommsCore.Beta.Record, as: BetaRecord\n"
                "  alias CommsCore.Repo\n"
                "  def owner_write do\n"
                "    query = from(record in Record, join: foreign in BetaRecord, "
                "on: foreign.id == record.id)\n"
                "    Repo.update_all(query, set: [status: :active])\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_not_rule(root, "direct_foreign_write")

    def test_rejects_a_foreign_write_through_a_local_repo_wrapper(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.Record\n"
                "  alias CommsCore.Repo\n"
                "  def change(attrs) do\n"
                "    %Record{}\n"
                "    |> Record.changeset(attrs)\n"
                "    |> persist()\n"
                "  end\n"
                "  defp persist(changeset), do: Repo.insert(changeset)\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "direct_foreign_write")

    def test_rejects_normalized_and_delegated_local_repo_wrappers(self) -> None:
        wrappers = (
            (
                "  alias CommsCore.Repo, as: R\n"
                "  defp persist(changeset), do: R.insert(changeset)\n"
            ),
            (
                "  alias CommsCore.Repo\n"
                "  defp persist(changeset) do\n"
                "    repo = Repo\n"
                "    repo.insert(changeset)\n"
                "  end\n"
            ),
            (
                "  alias CommsCore.Repo\n"
                "  defdelegate persist(changeset), to: Repo, as: :insert\n"
            ),
        )
        for wrapper in wrappers:
            with (
                self.subTest(wrapper=wrapper),
                self.boundary_fixture(allow_alpha=("beta",)) as root,
            ):
                self.write_schema(
                    root,
                    "CommsCore.Beta.Record",
                    "beta_records",
                    "beta/record.ex",
                )
                source = root / "apps/comms_core/lib/comms_core/alpha.ex"
                source.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Beta.Record\n"
                    "  def change, do: persist(%Record{})\n"
                    f"{wrapper}"
                    "end\n",
                    encoding="utf-8",
                )

                self.assert_rule(root, "direct_foreign_write")

    def test_repository_routes_governance_erasure_writes_through_owner_facades(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)
        source = (root / "apps/comms_core/lib/comms_core/governance.ex").read_text(
            encoding="utf-8"
        )

        self.assertEqual(
            [item for item in violations if item.rule == "direct_foreign_write"],
            [],
        )

        for owner_call in (
            "Accounts.erase_user_for_governance",
            "Attachments.mark_deleted_for_erasure",
            "Conversations.archive_for_erasure",
            "Conversations.remove_user_memberships_for_erasure",
            "Messaging.tombstone_for_erasure",
        ):
            self.assertIn(owner_call, source)

    def test_repository_contains_trust_governance_persistence_behind_owner_apis(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)

        trust_governance_prefixes = (
            "apps/comms_core/lib/comms_core/governance",
            "apps/comms_core/lib/comms_core/moderation",
        )
        foreign_schema_violations = [
            (item.path, item.detail)
            for item in violations
            if item.rule == "foreign_schema_import"
            and item.path.startswith(trust_governance_prefixes)
        ]
        self.assertEqual(foreign_schema_violations, [])

        scalar_fields = {
            "apps/comms_core/lib/comms_core/governance/deletion_request.ex": (
                "tenant_id",
                "requested_by_user_id",
                "subject_user_id",
                "conversation_id",
                "message_id",
            ),
            "apps/comms_core/lib/comms_core/governance/legal_hold.ex": (
                "tenant_id",
                "created_by_user_id",
                "subject_user_id",
                "conversation_id",
            ),
            "apps/comms_core/lib/comms_core/governance/retention_policy.ex": (
                "tenant_id",
                "conversation_id",
            ),
            "apps/comms_core/lib/comms_core/moderation/moderation_case.ex": (
                "tenant_id",
                "reporter_user_id",
                "subject_user_id",
                "conversation_id",
                "message_id",
                "assigned_to_user_id",
            ),
            "apps/comms_core/lib/comms_core/moderation/moderation_action.ex": (
                "tenant_id",
                "actor_user_id",
            ),
        }
        for relative_path, fields in scalar_fields.items():
            with self.subTest(schema=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                for field in fields:
                    self.assertIn(f"field(:{field}, Ecto.UUID)", source)

        moderation_action = (
            root / "apps/comms_core/lib/comms_core/moderation/moderation_action.ex"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "belongs_to(:moderation_case, CommsCore.Moderation.ModerationCase)",
            moderation_action,
        )

        owner_apis = {
            "apps/comms_core/lib/comms_core/accounts.ex": (
                "def validate_governance_user(",
                "def validate_moderation_assignee(",
                "def retention_actor_id(",
                "def ensure_governance_erasure_allowed(",
            ),
            "apps/comms_core/lib/comms_core/conversations.ex": (
                "def validate_reference(",
                "def retention_scope_ids(",
            ),
            "apps/comms_core/lib/comms_core/messaging.ex": (
                "def governance_impact(",
                "def retention_candidates(",
            ),
            "apps/comms_core/lib/comms_core/attachments.ex": ("def erasure_objects(",),
        }
        for relative_path, functions in owner_apis.items():
            with self.subTest(owner=relative_path):
                source = (root / relative_path).read_text(encoding="utf-8")
                for function in functions:
                    self.assertIn(function, source)

        governance_source = (
            root / "apps/comms_core/lib/comms_core/governance.ex"
        ).read_text(encoding="utf-8")
        moderation_source = (
            root / "apps/comms_core/lib/comms_core/moderation.ex"
        ).read_text(encoding="utf-8")
        for owner_call in (
            "Accounts.validate_governance_user",
            "Accounts.retention_actor_id",
            "Accounts.ensure_governance_erasure_allowed",
            "Conversations.validate_reference",
            "Conversations.retention_scope_ids",
            "Messaging.governance_impact",
            "Messaging.retention_candidates",
            "Attachments.erasure_objects",
        ):
            self.assertIn(owner_call, governance_source)
        for owner_call in (
            "Accounts.validate_governance_user",
            "Accounts.validate_moderation_assignee",
            "Conversations.validate_reference",
            "Messaging.governance_impact",
        ):
            self.assertIn(owner_call, moderation_source)

        dto_paths = {
            "CommsCore.Messaging.GovernanceImpact": "apps/comms_core/lib/comms_core/messaging/governance_impact.ex",
            "CommsCore.Messaging.RetentionScope": "apps/comms_core/lib/comms_core/messaging/retention_scope.ex",
            "CommsCore.Messaging.RetentionCandidate": "apps/comms_core/lib/comms_core/messaging/retention_candidate.ex",
            "CommsCore.Attachments.AttachmentDeletionObject": "apps/comms_core/lib/comms_core/attachments/attachment_deletion_object.ex",
        }
        declared_contracts = set(
            manifest["contexts"]["conversation_content"]["public_contracts"]
        )
        self.assertTrue(set(dto_paths).issubset(declared_contracts))
        for contract, relative_path in dto_paths.items():
            with self.subTest(contract=contract):
                source = (root / relative_path).read_text(encoding="utf-8")
                self.assertIn("defstruct", source)
                self.assertNotIn("use CommsCore.Schema", source)
                self.assertNotIn("use Ecto.Schema", source)
                self.assertNotIn('schema "', source)

    def test_repository_routes_user_lifecycle_and_retention_reads_one_way(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        accounts = (root / "apps/comms_core/lib/comms_core/accounts.ex").read_text(
            encoding="utf-8"
        )
        governance = (root / "apps/comms_core/lib/comms_core/governance.ex").read_text(
            encoding="utf-8"
        )
        retention_reader = (
            root
            / "apps/comms_core/lib/comms_core/governance/retention_defaults_reader.ex"
        ).read_text(encoding="utf-8")
        controller = (
            root / "apps/comms_web/lib/comms_web/controllers/admin_user_controller.ex"
        ).read_text(encoding="utf-8")

        self.assertNotIn("CommsCore.Governance", accounts)
        self.assertNotIn("DeletionRequest", accounts)
        self.assertIn("Accounts.apply_user_lifecycle_change", governance)
        self.assertNotRegex(
            governance, r"(?m)^\s*alias\s+CommsCore\.Administration\s*$"
        )
        self.assertNotIn("Administration.retention_defaults", governance)
        self.assertIn("Administration.retention_defaults", retention_reader)
        self.assertNotIn("TenantSettings", governance)
        self.assertNotIn("TenantSettings", retention_reader)
        self.assertIn("Governance.change_user_lifecycle_view", controller)
        self.assertNotIn("Accounts.change_user_with_effects_view", controller)

    def test_repository_accounts_uses_owner_facades_for_bootstrap_and_invitations(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        source = (root / "apps/comms_core/lib/comms_core/accounts.ex").read_text(
            encoding="utf-8"
        )
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)

        self.assertIn("Administration.append_bootstrap_tenant", source)
        self.assertIn("ConversationBootstrapPort.append_initial_channel", source)
        self.assertIn("ConversationBootstrapPort.create_initial_channel", source)
        self.assertIn("ConversationBootstrapPort.fetch_initial_channel", source)
        self.assertNotIn("CommsCore.Conversations", source)
        self.assertNotRegex(
            source,
            r"(?m)^\s*alias\s+CommsCore\.Administration\.Invitation\s*$",
        )
        self.assertNotIn("%Invitation{", source)
        self.assertNotIn("CommsCore.Conversations.Conversation", source)
        self.assertNotIn("CommsCore.Conversations.Membership", source)
        self.assertEqual(
            [
                item
                for item in violations
                if item.rule == "direct_foreign_write"
                and item.path == "apps/comms_core/lib/comms_core/accounts.ex"
            ],
            [],
        )

    def test_rejects_owner_only_schema_access_across_an_allowed_context_edge(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.Record\n"
                "  def read(record), do: record.id\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "foreign_schema_import")

    def test_canonical_schemas_are_owner_internal_without_an_opt_in_flag(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["tables"]["beta_records"].pop("access", None)
            manifest["tables"]["beta_records"].pop("access_namespaces", None)
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            foreign = root / "apps/comms_core/lib/comms_core/alpha.ex"
            foreign.parent.mkdir(parents=True, exist_ok=True)
            foreign.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.Record\n"
                "  def id(%Record{id: id}), do: id\n"
                "end\n",
                encoding="utf-8",
            )
            owner = root / "apps/comms_core/lib/comms_core/beta/reader.ex"
            owner.write_text(
                "defmodule CommsCore.Beta.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "  def id(%Record{id: id}), do: id\n"
                "end\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertTrue(
                any(
                    item.rule == "foreign_schema_import"
                    and item.path.endswith("alpha.ex")
                    for item in violations
                )
            )
            self.assertFalse(
                any(
                    item.rule in {"foreign_schema_import", "internal_schema_access"}
                    and item.path.endswith("beta/reader.ex")
                    for item in violations
                ),
                [item.render() for item in violations],
            )

    def test_rejects_a_forbidden_internal_namespace_dependency(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["namespace_dependency_rules"] = [
                {
                    "id": "alpha-does-not-import-beta",
                    "from": "CommsCore.Alpha",
                    "forbidden": ["CommsCore.Beta"],
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha/internal.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha.Internal do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "forbidden_namespace_dependency")

    def test_rejects_references_to_retired_context_modules(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["retired_modules"] = ["CommsCore.LegacyAlpha"]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            source = root / "apps/comms_web/lib/comms_web/legacy.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("alias CommsCore.LegacyAlpha\n", encoding="utf-8")

            self.assert_rule(root, "retired_context_module")

    def test_rejects_retired_namespace_descendants_in_code_and_config(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["retired_modules"] = ["CommsCore.Legacy"]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            source = root / "apps/comms_web/lib/comms_web/legacy.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsWeb.Legacy do\n"
                "  alias CommsCore.Legacy.Internal\n"
                "end\n",
                encoding="utf-8",
            )
            config = root / "config/config.exs"
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text(
                "import Config\n"
                "config :comms_core, legacy_adapter: "
                "CommsCore.Legacy.Adapter\n",
                encoding="utf-8",
            )

            violations = [
                item
                for item in analyze_context_boundaries(root, manifest)
                if item.rule == "retired_context_module"
            ]
            self.assertEqual(
                {item.path for item in violations},
                {
                    "apps/comms_web/lib/comms_web/legacy.ex",
                    "config/config.exs",
                },
            )

    def test_rejects_malformed_retired_module_tombstones(self) -> None:
        variants = (
            "CommsCore.Legacy",
            ["CommsCore.Legacy", "CommsCore.Legacy"],
            ["CommsCore.Zed", "CommsCore.AlphaLegacy"],
            ["Legacy"],
        )
        for retired_modules in variants:
            with (
                self.subTest(retired_modules=retired_modules),
                self.boundary_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["retired_modules"] = retired_modules
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )

                self.assert_rule(root, "invalid_context_declaration")

    def test_rejects_retired_runtime_binding_references(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["retired_runtime_bindings"] = [
                {
                    "application": "comms_core",
                    "key": "authorization_adapter",
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            source = root / "apps/comms_web/lib/comms_web/legacy.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsWeb.Legacy do\n"
                "  def adapter do\n"
                "    Application.fetch_env(:comms_core, :authorization_adapter)\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )
            config = root / "config/config.exs"
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text(
                "import Config\n"
                "config :comms_core,\n"
                "  authorization_adapter: CommsCore.Alpha\n",
                encoding="utf-8",
            )

            violations = [
                item
                for item in analyze_context_boundaries(root, manifest)
                if item.rule == "retired_runtime_binding"
            ]
            self.assertEqual(
                {item.path for item in violations},
                {
                    "apps/comms_web/lib/comms_web/legacy.ex",
                    "config/config.exs",
                },
            )

    def test_rejects_malformed_retired_runtime_binding_tombstones(self) -> None:
        variants = (
            "comms_core.authorization_adapter",
            [
                {
                    "application": "comms_core",
                    "key": "authorization_adapter",
                    "module": "CommsCore.Legacy",
                }
            ],
            [
                {
                    "application": "comms_core",
                    "key": "authorization_adapter",
                },
                {
                    "application": "comms_core",
                    "key": "authorization_adapter",
                },
            ],
            [
                {"application": "zeta", "key": "adapter"},
                {"application": "alpha", "key": "adapter"},
            ],
        )
        for retired_bindings in variants:
            with (
                self.subTest(retired_bindings=retired_bindings),
                self.boundary_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["retired_runtime_bindings"] = retired_bindings
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )

                self.assert_rule(root, "invalid_context_declaration")

    def test_rejects_mixed_owner_migrations_without_exception(self) -> None:
        with self.boundary_fixture() as root:
            migration = root / "apps/comms_core/priv/repo/migrations/1_mixed.exs"
            migration.parent.mkdir(parents=True, exist_ok=True)
            migration.write_text(
                "alter table(:alpha_records), do: add(:name, :text)\n"
                "alter table(:beta_records), do: add(:name, :text)\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "mixed_owner_migration")

    def test_rejects_public_facades_that_expose_ecto_schemas(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex"
            )
            facade = root / "apps/comms_core/lib/comms_core/alpha.ex"
            facade.parent.mkdir(parents=True, exist_ok=True)
            facade.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  @spec get(String.t()) :: CommsCore.Alpha.Record.t()\n"
                "  def get(id), do: id\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "public_ecto_contract")

    def test_rejects_alias_exposed_ecto_schema_in_public_spec(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            facade = root / "apps/comms_core/lib/comms_core/alpha.ex"
            facade.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Record\n"
                "  @spec get(String.t()) :: Record.t()\n"
                "  def get(id), do: id\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "public_ecto_contract")

    def test_alias_spec_does_not_confuse_record_view_with_schema(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            facade = root / "apps/comms_core/lib/comms_core/alpha.ex"
            facade.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Record\n"
                "  @spec get(String.t()) :: RecordView.t()\n"
                "  def get(id), do: id\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_not_rule(root, "public_ecto_contract")

    def test_public_contract_prefix_does_not_match_an_internal_schema(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex"
            )
            facade = root / "apps/comms_core/lib/comms_core/alpha.ex"
            facade.parent.mkdir(parents=True, exist_ok=True)
            facade.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  @spec get(String.t()) :: CommsCore.Alpha.RecordView.t()\n"
                "  def get(id), do: id\n"
                "end\n",
                encoding="utf-8",
            )

            self.assertNotIn(
                "public_ecto_contract",
                {
                    item.rule
                    for item in analyze_context_boundaries(
                        root,
                        read_yaml(
                            root / "docs/02-architecture/context-boundaries.yaml"
                        ),
                    )
                },
            )

    def test_rejects_business_context_cycles(self) -> None:
        with self.boundary_fixture(
            allow_alpha=("beta",), allow_beta=("alpha",)
        ) as root:
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            alpha.parent.mkdir(parents=True, exist_ok=True)
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n  alias CommsCore.Beta\nend\n",
                encoding="utf-8",
            )
            beta.write_text(
                "defmodule CommsCore.Beta do\n  alias CommsCore.Alpha\nend\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "business_context_cycle")

    def test_nested_grouped_alias_edges_participate_in_cycle_detection(
        self,
    ) -> None:
        with self.boundary_fixture(
            allow_alpha=("beta",), allow_beta=("alpha",)
        ) as root:
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            alpha.parent.mkdir(parents=True, exist_ok=True)
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n  alias CommsCore.{Beta.Record}\nend\n",
                encoding="utf-8",
            )
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            beta.write_text(
                "defmodule CommsCore.Beta do\n  alias CommsCore.Alpha\nend\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(
                root,
                read_yaml(root / "docs/02-architecture/context-boundaries.yaml"),
            )
            cycle = next(
                item for item in violations if item.rule == "business_context_cycle"
            )
            self.assertIn("alpha->beta", cycle.detail)
            self.assertIn("beta->alpha", cycle.detail)

    def test_multi_module_files_cannot_hide_facade_or_namespace_rules(
        self,
    ) -> None:
        sources = (
            (
                "facade.ex",
                "defmodule CommsCore.Alpha.Helper do\nend\n"
                "defmodule CommsCore.Alpha do\n"
                "  @spec get() :: CommsCore.Beta.Record.t()\n"
                "end\n",
            ),
            (
                "namespace.ex",
                "defmodule CommsCore.Alpha.Other do\nend\n"
                "defmodule CommsCore.Alpha.Internal do\n"
                "  alias CommsCore.Beta\n"
                "end\n",
            ),
        )
        for filename, source_text in sources:
            with self.subTest(filename=filename), self.boundary_fixture() as root:
                source = root / f"apps/comms_core/lib/comms_core/alpha/{filename}"
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(source_text, encoding="utf-8")
                manifest = read_yaml(
                    root / "docs/02-architecture/context-boundaries.yaml"
                )
                manifest["namespace_dependency_rules"] = [
                    {
                        "id": "alpha-internal-does-not-import-beta",
                        "from": "CommsCore.Alpha.Internal",
                        "forbidden": ["CommsCore.Beta"],
                    }
                ]
                violations = analyze_context_boundaries(root, manifest)
                matching = [
                    item
                    for item in violations
                    if item.rule == "multiple_context_modules_file"
                    and item.path.endswith(filename)
                ]

                self.assertEqual(len(matching), 1)
                with self.assertRaisesRegex(
                    ValueError,
                    "non-baselinable architecture violations",
                ):
                    write_baseline(root, violations)

    def test_multi_module_files_cannot_hide_a_second_ecto_schema(self) -> None:
        with self.boundary_fixture() as root:
            source = root / "apps/comms_core/lib/comms_core/alpha/hidden.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha.Helper do\nend\n"
                "defmodule CommsCore.Alpha.HiddenRecord do\n"
                '  schema "hidden_records" do\n'
                "  end\n"
                "end\n",
                encoding="utf-8",
            )
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            violations = analyze_context_boundaries(root, manifest)
            matching = [
                item
                for item in violations
                if item.rule == "multiple_context_modules_file"
            ]

            self.assertEqual(len(matching), 1)
            self.assertIn("CommsCore.Alpha.HiddenRecord", matching[0].detail)
            self.assertIn("hidden_records", matching[0].detail)
            with self.assertRaisesRegex(
                ValueError,
                "non-baselinable architecture violations",
            ):
                write_baseline(root, violations)

    def test_cycle_fingerprint_includes_the_exact_internal_edge_set(self) -> None:
        with self.boundary_fixture(
            allow_alpha=("beta",), allow_beta=("gamma",)
        ) as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["gamma"] = {
                "kind": "business",
                "public_facades": ["CommsCore.Gamma"],
                "public_contracts": [],
                "internal_namespaces": ["CommsCore.Gamma"],
                "allowed_dependencies": ["alpha"],
            }
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            gamma = root / "apps/comms_core/lib/comms_core/gamma.ex"
            alpha.parent.mkdir(parents=True, exist_ok=True)
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n  alias CommsCore.Beta\nend\n",
                encoding="utf-8",
            )
            beta.write_text(
                "defmodule CommsCore.Beta do\n  alias CommsCore.Gamma\nend\n",
                encoding="utf-8",
            )
            gamma.write_text(
                "defmodule CommsCore.Gamma do\n  alias CommsCore.Alpha\nend\n",
                encoding="utf-8",
            )

            first = next(
                item
                for item in analyze_context_boundaries(root, manifest)
                if item.rule == "business_context_cycle"
            )
            self.assertEqual(
                first.detail,
                "members: alpha, beta, gamma; "
                "edges: alpha->beta, beta->gamma, gamma->alpha",
            )

            manifest["contexts"]["alpha"]["allowed_dependencies"].append("gamma")
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n  alias CommsCore.{Beta, Gamma}\nend\n",
                encoding="utf-8",
            )
            second = next(
                item
                for item in analyze_context_boundaries(root, manifest)
                if item.rule == "business_context_cycle"
            )

            self.assertIn("alpha->gamma", second.detail)
            self.assertNotEqual(first.fingerprint, second.fingerprint)

    def test_read_model_reverse_edges_are_detected_without_an_exception(
        self,
    ) -> None:
        with self.boundary_fixture(allow_beta=("alpha",)) as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            beta.parent.mkdir(parents=True, exist_ok=True)
            beta.write_text(
                "defmodule CommsCore.Beta do\n  alias CommsCore.Alpha\nend\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertTrue(
                any(
                    item.rule == "read_model_reverse_dependency"
                    and "beta depends on read-model context alpha" in item.detail
                    for item in violations
                ),
                [item.render() for item in violations],
            )

    def test_allows_a_scoped_read_model_source_table_read(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-report",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Alpha may query beta records for this report only.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.Record\n"
                "  alias CommsCore.Repo\n"
                "  def list, do: Repo.all(Record)\n"
                "end\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertEqual(
                [
                    item
                    for item in violations
                    if item.rule
                    in {
                        "invalid_read_model_exception",
                        "read_model_scope_violation",
                        "foreign_schema_import",
                        "read_model_write",
                    }
                ],
                [],
            )

    def test_rejects_read_model_exception_without_a_condition(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-report",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("defmodule CommsCore.Alpha do\nend\n", encoding="utf-8")

            self.assert_rule(root, "invalid_read_model_exception")

    def test_allows_a_business_context_read_only_public_contract(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["contexts"]["beta"]["public_contracts"] = [
                "CommsCore.Beta.RecordView"
            ]
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-view",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Alpha consumes only Beta's published record view.",
                    "access": {
                        "public_contracts": ["CommsCore.Beta.RecordView"],
                        "public_queries": [],
                        "source_tables": [],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            contract = root / "apps/comms_core/lib/comms_core/beta/record_view.ex"
            contract.parent.mkdir(parents=True, exist_ok=True)
            contract.write_text(
                "defmodule CommsCore.Beta.RecordView do\nend\n", encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.RecordView\n"
                "  def render(%RecordView{} = view), do: view\n"
                "end\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertEqual(
                [
                    item
                    for item in violations
                    if item.rule
                    in {
                        "invalid_read_model_exception",
                        "read_model_scope_violation",
                    }
                ],
                [],
            )

    def test_allows_only_declared_public_query_calls_by_alias_or_full_name(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            beta.parent.mkdir(parents=True, exist_ok=True)
            beta.write_text(
                "defmodule CommsCore.Beta do\n"
                "  def lookup(id), do: id\n"
                "  def delete(id), do: id\n"
                "end\n",
                encoding="utf-8",
            )
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.{Beta}\n"
                "  def by_alias(id), do: Beta.lookup(id)\n"
                "  def fully_qualified(id), do: CommsCore.Beta.lookup(id)\n"
                "end\n",
                encoding="utf-8",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-query",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Alpha may call only Beta.lookup.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": ["CommsCore.Beta.lookup/1"],
                        "source_tables": [],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertEqual(
                [
                    item
                    for item in violations
                    if item.rule
                    in {
                        "invalid_read_model_exception",
                        "read_model_scope_violation",
                    }
                ],
                [],
            )

            alpha.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta\n"
                "  def delete(id), do: Beta.delete(id)\n"
                "end\n",
                encoding="utf-8",
            )
            self.assert_rule(root, "read_model_scope_violation")
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  def delete(id), do: CommsCore.Beta.delete(id)\n"
                "end\n",
                encoding="utf-8",
            )
            self.assert_rule(root, "read_model_scope_violation")

    def test_rejects_public_queries_not_owned_by_an_allowed_facade(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            alpha.parent.mkdir(parents=True, exist_ok=True)
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n  def lookup(id), do: id\nend\n",
                encoding="utf-8",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-query",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "The callable must belong to Beta.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": ["CommsCore.Alpha.lookup/1"],
                        "source_tables": [],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )

            self.assert_rule(root, "invalid_read_model_exception")

    def test_rejects_public_query_invocation_evasions_and_wrong_arity(
        self,
    ) -> None:
        unsafe_sources = (
            "  import CommsCore.Beta\n  def run(id), do: lookup(id)\n",
            "  alias CommsCore.Beta, as: Directory\n"
            "  import Directory\n"
            "  def run(id), do: lookup(id)\n",
            "  alias CommsCore.Beta\n  def run(id), do: Beta.lookup id\n",
            "  alias CommsCore.Beta\n  def run(id), do: apply(Beta, :lookup, [id])\n",
            "  alias CommsCore.Beta\n"
            "  def run(id), do: :erlang.apply(Beta, :lookup, [id])\n",
            "  alias CommsCore.Beta\n  def run, do: &Beta.delete/1\n",
            "  alias CommsCore.Beta\n"
            "  def run, do: Function.capture(Beta, :delete, 1)\n",
            "  alias CommsCore.Beta\n  def run(a, b), do: Beta.lookup(a, b)\n",
            "  alias CommsCore.Beta\n"
            "  @directory Beta\n"
            "  def run(id), do: @directory.delete(id)\n",
            "  alias CommsCore.Beta\n  defdelegate run(id), to: Beta, as: :delete\n",
        )

        for index, unsafe_source in enumerate(unsafe_sources):
            with (
                self.subTest(index=index),
                self.boundary_fixture(allow_alpha=("beta",)) as root,
            ):
                beta = root / "apps/comms_core/lib/comms_core/beta.ex"
                beta.parent.mkdir(parents=True, exist_ok=True)
                beta.write_text(
                    "defmodule CommsCore.Beta do\n"
                    "  def lookup(id), do: id\n"
                    "  def lookup(left, right), do: {left, right}\n"
                    "  def delete(id), do: id\n"
                    "end\n",
                    encoding="utf-8",
                )
                alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
                alpha.write_text(
                    f"defmodule CommsCore.Alpha do\n{unsafe_source}end\n",
                    encoding="utf-8",
                )
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["contexts"]["alpha"]["kind"] = "business"
                manifest["contexts"]["beta"]["kind"] = "business"
                manifest["read_model_exceptions"] = [
                    {
                        "id": "alpha-beta-query",
                        "module": "CommsCore.Alpha",
                        "mode": "read_only",
                        "owners": ["beta"],
                        "condition": "Only Beta.lookup/1 is allowed.",
                        "access": {
                            "public_contracts": [],
                            "public_queries": ["CommsCore.Beta.lookup/1"],
                            "source_tables": [],
                        },
                    }
                ]
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
                )

                self.assert_rule(root, "read_model_scope_violation")

    def test_scoped_read_model_dependency_cannot_move_to_a_sibling_helper(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            beta.parent.mkdir(parents=True, exist_ok=True)
            beta.write_text(
                "defmodule CommsCore.Beta do\n  def lookup(id), do: id\nend\n",
                encoding="utf-8",
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.parent.mkdir(parents=True, exist_ok=True)
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta\n"
                "  def lookup(id), do: Beta.lookup(id)\n"
                "end\n",
                encoding="utf-8",
            )
            bypass = root / "apps/comms_core/lib/comms_core/alpha/bypass.ex"
            bypass.write_text(
                "defmodule CommsCore.Alpha.Bypass do\n"
                "  alias CommsCore.Beta\n"
                "  def lookup(id), do: Beta.lookup(id)\n"
                "end\n",
                encoding="utf-8",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-query",
                    "module": "CommsCore.Alpha.Reader",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Only the reader may call Beta.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": ["CommsCore.Beta.lookup/1"],
                        "source_tables": [],
                    },
                }
            ]

            violations = analyze_context_boundaries(root, manifest)
            self.assertTrue(
                any(
                    item.rule == "read_model_scope_violation"
                    and item.path.endswith("alpha/bypass.ex")
                    and "bypasses the scoped read-model module" in item.detail
                    for item in violations
                ),
                [item.render() for item in violations],
            )

    def test_rejects_source_table_access_for_a_business_context_exception(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-table",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Business contexts may not read source tables.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("defmodule CommsCore.Alpha do\nend\n", encoding="utf-8")

            self.assert_rule(root, "invalid_read_model_exception")

    def test_rejects_read_model_targets_outside_the_explicit_access_scope(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["contexts"]["beta"]["public_contracts"] = [
                "CommsCore.Beta.RecordView"
            ]
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-view",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Only the declared Beta record view is in scope.",
                    "access": {
                        "public_contracts": ["CommsCore.Beta.RecordView"],
                        "public_queries": [],
                        "source_tables": [],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            contract = root / "apps/comms_core/lib/comms_core/beta/record_view.ex"
            contract.parent.mkdir(parents=True, exist_ok=True)
            contract.write_text(
                "defmodule CommsCore.Beta.RecordView do\nend\n", encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.InternalQuery\n"
                "  def list, do: InternalQuery.list()\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "read_model_scope_violation")

    def test_read_model_source_table_grants_never_suppress_writes(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-report",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "The grant is read-only and cannot suppress writes.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  import Ecto.Query\n"
                "  alias CommsCore.Beta.Record\n"
                "  alias CommsCore.Repo\n"
                "  def delete, do: Repo.delete_all(from(record in Record))\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "direct_foreign_write")
            self.assert_rule(root, "read_model_write")

    def test_read_model_exceptions_reject_all_mutation_and_raw_sql_evasions(
        self,
    ) -> None:
        unsafe_bodies = (
            "  def mutate, do: Repo.update_all(CommsCore.Alpha.Record, "
            "set: [status: :closed])\n",
            "  def mutate(record), do: CommsCore.Repo.insert(record)\n",
            "  alias CommsCore.Repo, as: Database\n"
            "  def mutate(record), do: Database.delete(record)\n",
            "  alias Ecto.Multi, as: Transaction\n"
            "  def mutate(changeset), do: "
            "Transaction.new() |> Transaction.update(:record, changeset)\n",
            "  alias Oban, as: Jobs\n  def mutate(job), do: Jobs.insert(job)\n",
            "  import CommsCore.Repo\n",
            "  alias CommsCore.Repo, as: Database\n  import Database\n",
            "  def mutate(changeset), do: Repo.update changeset\n",
            "  def mutate(record), do: apply(Repo, :delete, [record])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            "\"UPDATE beta_records SET status = 'closed'\", [])\n",
            '  @mutation "DELETE FROM beta_records"\n'
            "  def mutate, do: Ecto.Adapters.SQL.query!(Repo, @mutation, [])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            '"CREATE INDEX unsafe_idx ON beta_records (id)", [])\n',
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            '"DROP INDEX unsafe_idx", [])\n',
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            '"ALTER INDEX unsafe_idx RENAME TO worse_idx", [])\n',
            "  def mutate(statement), do: "
            "Ecto.Adapters.SQL.query(Repo, statement, [])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            '"VACUUM beta_records", [])\n',
            "  alias Ecto.Adapters.SQL, as: Database\n"
            "  def mutate(statement), do: Database.query(Repo, statement, [])\n",
            "  import Ecto.Adapters.SQL\n"
            "  def mutate(statement), do: query(Repo, statement, [])\n",
            "  def mutate(statement), do: "
            "apply(Ecto.Adapters.SQL, :query, [Repo, statement, []])\n",
            "  def mutate(statement), do: "
            "Ecto.Adapters.SQL.query Repo, statement, []\n",
            "  alias Ecto.Adapters.SQL, as: Database\n  import Database\n",
            "  alias Ecto.Adapters.SQL, as: Database\n"
            "  def mutate, do: &Database.query/4\n",
            "  alias Ecto.Adapters.SQL\n"
            "  def mutate(statement) do\n"
            "    db = SQL\n"
            "    db.query(Repo, statement, [])\n"
            "  end\n",
            "  defdelegate query(repo, statement, args), to: Ecto.Adapters.SQL\n",
        )

        for index, body in enumerate(unsafe_bodies):
            with (
                self.subTest(index=index),
                self.boundary_fixture(allow_alpha=("beta",)) as root,
            ):
                self.write_schema(
                    root,
                    "CommsCore.Alpha.Record",
                    "alpha_records",
                    "alpha/record.ex",
                )
                self.write_schema(
                    root,
                    "CommsCore.Beta.Record",
                    "beta_records",
                    "beta/record.ex",
                )
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["contexts"]["alpha"]["kind"] = "business_read_model"
                manifest["contexts"]["beta"]["kind"] = "business"
                manifest["read_model_exceptions"] = [
                    {
                        "id": "alpha-beta-report",
                        "module": "CommsCore.Alpha",
                        "mode": "read_only",
                        "owners": ["beta"],
                        "condition": "The exception permits reads only.",
                        "access": {
                            "public_contracts": [],
                            "public_queries": [],
                            "source_tables": ["beta_records"],
                        },
                    }
                ]
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
                )
                source = root / "apps/comms_core/lib/comms_core/alpha.ex"
                source.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Repo\n"
                    f"{body}"
                    "end\n",
                    encoding="utf-8",
                )

                self.assert_rule(root, "read_model_write")

    def test_read_model_allows_statically_reviewable_select_sql(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-report",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Only a static SELECT is used.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                }
            ]
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Repo\n"
                "  def read, do: Ecto.Adapters.SQL.query("
                'Repo, "SELECT id FROM beta_records", [])\n'
                "end\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertFalse(
                any(item.rule == "read_model_write" for item in violations),
                [item.render() for item in violations],
            )

    def test_every_module_in_a_business_read_model_context_is_read_only(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            writer = root / "apps/comms_core/lib/comms_core/alpha/writer.ex"
            writer.parent.mkdir(parents=True, exist_ok=True)
            writer.write_text(
                "defmodule CommsCore.Alpha.Writer do\n"
                "  alias CommsCore.Repo\n"
                "  def write(record), do: Repo.insert(record)\n"
                "end\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            self.assertTrue(
                any(
                    item.rule == "read_model_write"
                    and item.path.endswith("alpha/writer.ex")
                    for item in violations
                ),
                [item.render() for item in violations],
            )

    def test_read_model_exceptions_never_suppress_reverse_edges_or_cycles(self) -> None:
        with self.boundary_fixture(
            allow_alpha=("beta",), allow_beta=("alpha",)
        ) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-report",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "The grant cannot suppress graph direction.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            alpha.parent.mkdir(parents=True, exist_ok=True)
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Beta.Record\n"
                "  def render(%Record{} = record), do: record\n"
                "end\n",
                encoding="utf-8",
            )
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            beta.write_text(
                "defmodule CommsCore.Beta do\n  alias CommsCore.Alpha\nend\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "read_model_reverse_dependency")
            self.assert_rule(root, "business_context_cycle")

    def test_read_model_control_violations_cannot_be_grandfathered(self) -> None:
        with self.boundary_fixture(
            allow_alpha=("beta",), allow_beta=("alpha",)
        ) as root:
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["kind"] = "business_read_model"
            manifest["contexts"]["beta"]["kind"] = "business"
            manifest["read_model_exceptions"] = [
                {
                    "id": "alpha-beta-report",
                    "module": "CommsCore.Alpha",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "The grant cannot suppress integrity failures.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                },
                {
                    "id": "invalid-missing-module",
                    "module": "CommsCore.MissingReadModel",
                    "mode": "read_only",
                    "owners": ["beta"],
                    "condition": "Missing modules remain invalid.",
                    "access": {
                        "public_contracts": [],
                        "public_queries": [],
                        "source_tables": ["beta_records"],
                    },
                },
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8"
            )
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            alpha.parent.mkdir(parents=True, exist_ok=True)
            alpha.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  import Ecto.Query\n"
                "  alias CommsCore.Beta.InternalQuery\n"
                "  alias CommsCore.Beta.Record\n"
                "  alias CommsCore.Repo\n"
                "  def list, do: InternalQuery.list()\n"
                "  def delete, do: Repo.delete_all(from(record in Record))\n"
                "end\n",
                encoding="utf-8",
            )
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            beta.write_text(
                "defmodule CommsCore.Beta do\n  alias CommsCore.Alpha\nend\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(root, manifest)
            control_rules = {
                "direct_foreign_write",
                "invalid_read_model_exception",
                "read_model_scope_violation",
                "read_model_write",
                "read_model_reverse_dependency",
            }
            with self.assertRaisesRegex(
                ValueError,
                "refusing to baseline non-baselinable architecture violations",
            ):
                write_baseline(root, violations)
            write_baseline(
                root,
                [item for item in violations if item.rule not in control_rules],
            )
            self.declare_current_baseline_deferrals(root)
            errors = validate(root)
            rendered = "\n".join(errors)
            for rule in control_rules:
                self.assertIn(f"[{rule}]", rendered)
            self.assertTrue(
                all(
                    error.startswith(
                        (
                            "READ-MODEL control violation:",
                            "NON-BASELINABLE architecture violation:",
                        )
                    )
                    for error in errors
                ),
                errors,
            )

    def test_rejects_unclassified_and_ambiguous_production_modules(self) -> None:
        with self.boundary_fixture() as root:
            future = root / "apps/comms_core/lib/comms_core/future.ex"
            future.parent.mkdir(parents=True, exist_ok=True)
            future.write_text(
                "defmodule CommsCore.Future do\nend\n",
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any("[unclassified_core_module]" in error for error in errors),
                errors,
            )
            self.assertTrue(
                any(
                    error.startswith("NON-BASELINABLE architecture violation:")
                    for error in errors
                ),
                errors,
            )

            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["owned_modules"] = ["CommsCore.Future"]
            manifest["contexts"]["beta"]["owned_modules"] = ["CommsCore.Future"]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any("[ambiguous_context_owner]" in error for error in errors),
                errors,
            )

    def test_validates_exact_configured_technical_interface(self) -> None:
        with self.technical_interface_fixture() as root:
            self.assertEqual(validate(root), [])

    def test_rejects_technical_interface_contract_drift(self) -> None:
        mutations = (
            (
                "caller",
                lambda item: item.update(callers=["CommsCore.Alpha.Missing"]),
            ),
            (
                "operation",
                lambda item: item.update(operations=[{"name": "execute", "arity": 2}]),
            ),
            (
                "behaviour",
                lambda item: item.update(behaviour="CommsCore.Alpha.MissingContract"),
            ),
            (
                "implementation",
                lambda item: item.update(implementation="CommsWeb.MissingAdapter"),
            ),
            (
                "binding",
                lambda item: item["binding"].update(key="wrong_adapter"),
            ),
            (
                "contract",
                lambda item: item.update(contracts=["CommsCore.Alpha.MissingPayload"]),
            ),
            ("empty contracts", lambda item: item.update(contracts=[])),
            ("transaction", lambda item: item.update(transaction="eventual")),
        )
        for label, mutate in mutations:
            with (
                self.subTest(label=label),
                self.technical_interface_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                mutate(manifest["technical_interfaces"][0])
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any("[invalid_technical_interface]" in error for error in errors),
                    errors,
                )

    def test_rejects_undeclared_technical_interface_operation(self) -> None:
        with self.technical_interface_fixture() as root:
            dispatcher = root / "apps/comms_core/lib/comms_core/alpha/dispatcher.ex"
            dispatcher_text = dispatcher.read_text(encoding="utf-8")
            dispatcher_body, module_end = dispatcher_text.rsplit("\nend\n", 1)
            dispatcher.write_text(
                dispatcher_body
                + "\n  def unsafe(payload), do: payload\nend\n"
                + module_end,
                encoding="utf-8",
            )
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
                "  def run do\n"
                '    payload = %Payload{id: "fixture"}\n'
                "    Dispatcher.execute(payload)\n"
                "    Dispatcher.unsafe(payload)\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "invokes undeclared operations" in error and "unsafe/1" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_undeclared_operation_from_another_released_adapter(
        self,
    ) -> None:
        with self.technical_interface_fixture() as root:
            rogue = root / "apps/comms_web/lib/comms_web/rogue_adapter.ex"
            rogue.write_text(
                "defmodule CommsWeb.RogueAdapter do\n"
                "  alias CommsCore.Alpha.Dispatcher\n"
                "  def run(payload), do: Dispatcher.unsafe(payload)\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "caller CommsWeb.RogueAdapter invokes undeclared operations"
                    in error
                    and "unsafe/1" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_same_owner_rogue_technical_interface_callers(self) -> None:
        mutations = (
            (
                "declared operation",
                "Dispatcher.execute(payload)",
                "caller set differs from source",
            ),
            (
                "undeclared operation",
                "Dispatcher.unsafe(payload)",
                "invokes undeclared operations",
            ),
        )
        for label, invocation, expected in mutations:
            with self.subTest(label=label), self.technical_interface_fixture() as root:
                rogue = root / "apps/comms_core/lib/comms_core/alpha/rogue.ex"
                rogue.write_text(
                    "defmodule CommsCore.Alpha.Rogue do\n"
                    "  alias CommsCore.Alpha.Dispatcher\n"
                    f"  def run(payload), do: {invocation}\n"
                    "end\n",
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any(
                        expected in error and "CommsCore.Alpha.Rogue" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_rejects_dynamic_undeclared_technical_interface_operation(
        self,
    ) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
                "  def run do\n"
                '    payload = %Payload{id: "fixture"}\n'
                "    Dispatcher.execute(payload)\n"
                "    apply(Dispatcher, :unsafe, [payload])\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "uses an unenforceable interface invocation" in error
                    and "uses dynamic CommsCore.Alpha.Dispatcher.unsafe" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_dynamic_variable_technical_interface_operation(
        self,
    ) -> None:
        invocations = (
            "apply(Dispatcher, operation, [payload])",
            "Function.capture(Dispatcher, operation, 1)",
        )
        for invocation in invocations:
            with (
                self.subTest(invocation=invocation),
                self.technical_interface_fixture() as root,
            ):
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
                    "  def run(operation) do\n"
                    '    payload = %Payload{id: "fixture"}\n'
                    "    Dispatcher.execute(payload)\n"
                    f"    {invocation}\n"
                    "  end\n"
                    "end\n",
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any(
                        "uses dynamic "
                        "CommsCore.Alpha.Dispatcher.<non-literal operation>" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_rejects_dynamic_variable_technical_interface_module(
        self,
    ) -> None:
        invocations = (
            "apply(target, :unsafe, [payload])",
            "Function.capture(target, :unsafe, 1)",
        )
        for invocation in invocations:
            with (
                self.subTest(invocation=invocation),
                self.technical_interface_fixture() as root,
            ):
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
                    "  def run do\n"
                    '    payload = %Payload{id: "fixture"}\n'
                    "    Dispatcher.execute(payload)\n"
                    "    target = Dispatcher\n"
                    f"    {invocation}\n"
                    "  end\n"
                    "end\n",
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any(
                        "uses dynamic CommsCore.Alpha.Dispatcher.unsafe" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_rejects_parenless_dynamic_technical_interface_invocations(
        self,
    ) -> None:
        invocations = (
            (
                "apply target, :unsafe, [payload]",
                "uses dynamic CommsCore.Alpha.Dispatcher.unsafe",
            ),
            (
                "Kernel.apply target, operation, [payload]",
                "uses dynamic CommsCore.Alpha.Dispatcher.<non-literal operation>",
            ),
            (
                ":erlang.apply target, :unsafe, [payload]",
                "uses dynamic CommsCore.Alpha.Dispatcher.unsafe",
            ),
            (
                "Function.capture target, operation, 1",
                "uses dynamic CommsCore.Alpha.Dispatcher.<non-literal operation>",
            ),
            (
                "apply target,\n      :unsafe,\n      [payload]",
                "uses dynamic CommsCore.Alpha.Dispatcher.unsafe",
            ),
            (
                "Function.capture target,\n      operation,\n      1",
                "uses dynamic CommsCore.Alpha.Dispatcher.<non-literal operation>",
            ),
        )
        for invocation, expected in invocations:
            with (
                self.subTest(invocation=invocation),
                self.technical_interface_fixture() as root,
            ):
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
                    "  def run(operation) do\n"
                    '    payload = %Payload{id: "fixture"}\n'
                    "    Dispatcher.execute(payload)\n"
                    "    target = Dispatcher\n"
                    f"    {invocation}\n"
                    "  end\n"
                    "end\n",
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any(expected in error for error in errors),
                    errors,
                )

    def test_rejects_module_attribute_dynamic_technical_invocations(
        self,
    ) -> None:
        invocations = (
            (
                "apply(@target, :unsafe, [payload])",
                "uses dynamic CommsCore.Alpha.Dispatcher.unsafe",
            ),
            (
                "apply @target, operation, [payload]",
                "uses dynamic CommsCore.Alpha.Dispatcher.<non-literal operation>",
            ),
            (
                "Function.capture(@target, :unsafe, 1)",
                "uses dynamic CommsCore.Alpha.Dispatcher.unsafe",
            ),
            (
                "Function.capture @target, operation, 1",
                "uses dynamic CommsCore.Alpha.Dispatcher.<non-literal operation>",
            ),
        )
        for invocation, expected in invocations:
            with (
                self.subTest(invocation=invocation),
                self.technical_interface_fixture() as root,
            ):
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
                    "  @target Dispatcher\n"
                    "  def run(operation) do\n"
                    '    payload = %Payload{id: "fixture"}\n'
                    "    Dispatcher.execute(payload)\n"
                    f"    {invocation}\n"
                    "  end\n"
                    "end\n",
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any(expected in error for error in errors),
                    errors,
                )

    def test_rejects_tracked_static_remote_technical_calls(self) -> None:
        invocations = (
            "target.unsafe(payload)",
            "target.unsafe payload",
            "&target.unsafe/1",
            "@target.unsafe(payload)",
            "@target.unsafe payload",
            "&@target.unsafe/1",
        )
        for invocation in invocations:
            with (
                self.subTest(invocation=invocation),
                self.technical_interface_fixture() as root,
            ):
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
                    "  @target Dispatcher\n"
                    "  def run do\n"
                    '    payload = %Payload{id: "fixture"}\n'
                    "    Dispatcher.execute(payload)\n"
                    "    target = Dispatcher\n"
                    f"    {invocation}\n"
                    "  end\n"
                    "end\n",
                    encoding="utf-8",
                )

                errors = validate(root)
                self.assertTrue(
                    any(
                        "CommsCore.Alpha.Dispatcher.unsafe" in error
                        or (
                            "invokes undeclared operations" in error
                            and "unsafe/1" in error
                        )
                        for error in errors
                    ),
                    errors,
                )

    def test_defdelegate_participates_in_exact_technical_contracts(self) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Dispatcher\n"
                "  defdelegate execute(payload), to: Dispatcher\n"
                "end\n",
                encoding="utf-8",
            )
            self.assertEqual(validate(root), [])

        mutations = (
            "defdelegate run(payload), to: Dispatcher, as: :unsafe",
            (
                "target = Dispatcher\n"
                "  defdelegate run(payload), to: target, as: :unsafe"
            ),
        )
        for declaration in mutations:
            with (
                self.subTest(declaration=declaration),
                self.technical_interface_fixture() as root,
            ):
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    "  alias CommsCore.Alpha.Dispatcher\n"
                    f"  {declaration}\n"
                    "  def execute(payload), do: Dispatcher.execute(payload)\n"
                    "end\n",
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any(
                        "invokes undeclared operations" in error and "unsafe/1" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_rejects_unknown_dynamic_target_in_technical_caller(self) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Dispatcher\n"
                "  def run(payload) do\n"
                "    Dispatcher.execute(payload)\n"
                "    target = target_from_helper()\n"
                "    apply(target, :unsafe, [payload])\n"
                "  end\n"
                "  defp target_from_helper, do: Dispatcher\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "CommsCore.Alpha.Dispatcher.<unknown module target>" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_ambiguous_static_technical_binding(self) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Dispatcher\n"
                "  def run(payload) do\n"
                "    Dispatcher.execute(payload)\n"
                "    target = Dispatcher\n"
                "    target = CommsCore.Alpha.Other\n"
                "    apply(target, :unsafe, [payload])\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any("ambiguously binds target" in error for error in errors),
                errors,
            )

    def test_rejects_ambiguous_technical_alias_rebinding(self) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias(CommsCore.Alpha.Dispatcher, as: Target)\n"
                "  alias CommsCore.Alpha.Other, as: Target, warn: false\n"
                "  def run(payload) do\n"
                "    CommsCore.Alpha.Dispatcher.execute(payload)\n"
                "    Target.unsafe(payload)\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any("ambiguously aliases Target" in error for error in errors),
                errors,
            )

    def test_normalizes_elixir_and_prefix_alias_technical_calls(self) -> None:
        invocations = (
            "Elixir.CommsCore.Alpha.Dispatcher.unsafe(payload)",
            "Core.Alpha.Dispatcher.unsafe(payload)",
        )
        for invocation in invocations:
            with (
                self.subTest(invocation=invocation),
                self.technical_interface_fixture() as root,
            ):
                rogue = root / "apps/comms_core/lib/comms_core/alpha/rogue.ex"
                rogue.write_text(
                    "defmodule CommsCore.Alpha.Rogue do\n"
                    "  alias CommsCore, as: Core\n"
                    f"  def run(payload), do: {invocation}\n"
                    "end\n",
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any(
                        "invokes undeclared operations" in error and "unsafe/1" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_normalizes_elixir_module_declarations_and_config_binding(
        self,
    ) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                caller.read_text(encoding="utf-8").replace(
                    "defmodule CommsCore.Alpha",
                    "defmodule Elixir.CommsCore.Alpha",
                ),
                encoding="utf-8",
            )
            implementation = root / "apps/comms_web/lib/comms_web/alpha_adapter.ex"
            implementation.write_text(
                implementation.read_text(encoding="utf-8").replace(
                    "defmodule CommsWeb.AlphaAdapter",
                    "defmodule Elixir.CommsWeb.AlphaAdapter",
                ),
                encoding="utf-8",
            )
            config = root / "config/config.exs"
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    "CommsWeb.AlphaAdapter",
                    "Elixir.CommsWeb.AlphaAdapter",
                ),
                encoding="utf-8",
            )

            self.assertEqual(validate(root), [])

    def test_alias_options_preserve_exact_technical_call_resolution(self) -> None:
        aliases = (
            "alias CommsCore.Alpha.Dispatcher, warn: false",
            "alias CommsCore.Alpha.Dispatcher, as: D, warn: false",
            ("alias CommsCore.Alpha.Dispatcher,\n    as: D,\n    warn: false"),
        )
        for alias_declaration in aliases:
            with (
                self.subTest(alias_declaration=alias_declaration),
                self.technical_interface_fixture() as root,
            ):
                receiver = "Dispatcher" if "as:" not in alias_declaration else "D"
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    "defmodule CommsCore.Alpha do\n"
                    f"  {alias_declaration}\n"
                    "  alias CommsCore.Alpha.Payload\n"
                    f'  def run, do: {receiver}.execute(%Payload{{id: "fixture"}})\n'
                    "end\n",
                    encoding="utf-8",
                )

                self.assertEqual(validate(root), [])

    def test_parenthesized_alias_and_import_directives_are_enforced(self) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias(CommsCore, as: Core)\n"
                "  alias CommsCore.Alpha.Payload\n"
                "  def run(payload), do: "
                "Core.Alpha.Dispatcher.execute(payload)\n"
                "end\n",
                encoding="utf-8",
            )
            self.assertEqual(validate(root), [])

        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.Alpha.Dispatcher\n"
                "  import(CommsCore.Alpha.Dispatcher, only: [unsafe: 1])\n"
                "  def run(payload) do\n"
                "    Dispatcher.execute(payload)\n"
                "    unsafe(payload)\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any("imports CommsCore.Alpha.Dispatcher" in error for error in errors),
                errors,
            )

    def test_configured_interface_parses_all_literal_application_bindings(
        self,
    ) -> None:
        bindings = (
            "Application.get_env :comms_core, :alpha_technical_adapter",
            "Application.fetch_env! :comms_core, :alpha_technical_adapter",
            "Application.compile_env(:comms_core, :alpha_technical_adapter)",
            "Application.compile_env! :comms_core, :alpha_technical_adapter",
        )
        for binding in bindings:
            with (
                self.subTest(binding=binding),
                self.technical_interface_fixture() as root,
            ):
                dispatcher = root / "apps/comms_core/lib/comms_core/alpha/dispatcher.ex"
                dispatcher.write_text(
                    dispatcher.read_text(encoding="utf-8").replace(
                        "Application.get_env(:comms_core, :alpha_technical_adapter)",
                        binding,
                    ),
                    encoding="utf-8",
                )
                self.assertEqual(validate(root), [])

        with self.technical_interface_fixture() as root:
            dispatcher = root / "apps/comms_core/lib/comms_core/alpha/dispatcher.ex"
            dispatcher.write_text(
                dispatcher.read_text(encoding="utf-8").replace(
                    "Application.get_env(:comms_core, :alpha_technical_adapter)",
                    "Application.get_env(application, key)",
                ),
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any(
                    "uses a non-literal application or key" in error for error in errors
                ),
                errors,
            )

    def test_rejects_unresolved_application_binding_outside_interface_module(
        self,
    ) -> None:
        with self.technical_interface_fixture() as root:
            source = root / "apps/comms_core/lib/comms_core/beta/dynamic_binding.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Beta.DynamicBinding do\n"
                "  def resolve(application, key), "
                "do: Application.get_env(application, key)\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "uses an unenforceable configured binding" in error
                    and "uses a non-literal application or key" in error
                    for error in errors
                ),
                errors,
            )

    def test_configured_interface_accepts_parenthesized_config_binding(
        self,
    ) -> None:
        with self.technical_interface_fixture() as root:
            config = root / "config/config.exs"
            config.write_text(
                "import Config\n"
                "config(:comms_core, :alpha_technical_adapter, "
                "CommsWeb.AlphaAdapter)\n",
                encoding="utf-8",
            )

            self.assertEqual(validate(root), [])

    def test_rejects_declared_technical_operation_without_a_declared_caller_use(
        self,
    ) -> None:
        with self.technical_interface_fixture() as root:
            caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
            caller.write_text(
                "defmodule CommsCore.Alpha do\n  def run(payload), do: payload\nend\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "declared operations are not used by a declared caller" in error
                    and "execute/1" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_missing_or_removed_technical_interface_declarations(
        self,
    ) -> None:
        for mutation in ("missing", "empty"):
            with (
                self.subTest(mutation=mutation),
                self.technical_interface_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                if mutation == "missing":
                    manifest.pop("technical_interfaces")
                else:
                    manifest["technical_interfaces"] = []
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any("[invalid_technical_interface]" in error for error in errors),
                    errors,
                )

    def test_rejects_adapter_internal_modules_including_hidden_projectors(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
            alpha.parent.mkdir(parents=True, exist_ok=True)
            alpha.write_text(
                "defmodule CommsCore.Alpha do\nend\n",
                encoding="utf-8",
            )
            projector = root / "apps/comms_core/lib/comms_core/alpha/projector.ex"
            projector.parent.mkdir(parents=True, exist_ok=True)
            projector.write_text(
                "defmodule CommsCore.Alpha.Projector do\n"
                "  @moduledoc false\n"
                "  def project(value), do: value\n"
                "end\n",
                encoding="utf-8",
            )
            leak = root / "apps/comms_web/lib/comms_web/leak.ex"
            leak.parent.mkdir(parents=True, exist_ok=True)
            leak.write_text(
                "defmodule CommsWeb.Leak do\n"
                "  alias CommsCore.Alpha.Projector\n"
                "  def run(value), do: Projector.project(value)\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "adapter_internal_module_import")

    def test_adapter_schema_import_is_not_duplicated_as_internal_import(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            leak = root / "apps/comms_web/lib/comms_web/schema_leak.ex"
            leak.parent.mkdir(parents=True, exist_ok=True)
            leak.write_text(
                "defmodule CommsWeb.SchemaLeak do\n"
                "  alias CommsCore.Alpha.Record\n"
                "  def run(%Record{} = record), do: record\n"
                "end\n",
                encoding="utf-8",
            )
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            rules = {
                item.rule
                for item in analyze_context_boundaries(root, manifest)
                if item.path == "apps/comms_web/lib/comms_web/schema_leak.ex"
            }
            self.assertEqual(rules, {"adapter_schema_import"})

    def test_strict_deferrals_reject_debt_outside_allowed_contexts(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["calls"] = {
                "public_facades": [],
                "public_contracts": [],
                "internal_namespaces": ["CommsCore.Calls"],
                "allowed_dependencies": [],
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            write_current_baseline(root)
            self.declare_current_baseline_deferrals(root)

            manifest = read_yaml(manifest_path)
            manifest["enforcement"]["mode"] = "strict_with_explicit_deferrals"
            manifest["enforcement"]["target_mode"] = "strict_with_explicit_deferrals"
            manifest["enforcement"]["strict_with_explicit_deferrals"] = {
                "active": True,
                "exact_mapping": True,
                "reject_missing_declarations": True,
                "reject_stale_declarations": True,
                "reject_duplicate_fingerprints": True,
                "require_base_branch_no_growth": True,
                "require_deterministic_report": True,
                "allowed_deferral_contexts": ["calls"],
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any("outside allowed_deferral_contexts" in error for error in errors),
                errors,
            )

    def test_strict_deferrals_reject_independent_cycle_hidden_by_allowed_context(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["contexts"]["alpha"]["allowed_dependencies"] = [
                "beta",
                "calls",
            ]
            manifest["contexts"]["beta"]["allowed_dependencies"] = ["alpha"]
            manifest["contexts"]["calls"] = {
                "public_facades": ["CommsCore.Calls"],
                "public_contracts": [],
                "internal_namespaces": ["CommsCore.Calls"],
                "allowed_dependencies": ["alpha"],
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            (root / "apps/comms_core/lib/comms_core/alpha.ex").write_text(
                "defmodule CommsCore.Alpha do\n"
                "  def run(value) do\n"
                "    {CommsCore.Beta.run(value), CommsCore.Calls.run(value)}\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )
            (root / "apps/comms_core/lib/comms_core/beta.ex").write_text(
                "defmodule CommsCore.Beta do\n"
                "  def run(value), do: CommsCore.Alpha.run(value)\n"
                "end\n",
                encoding="utf-8",
            )
            (root / "apps/comms_core/lib/comms_core/calls.ex").write_text(
                "defmodule CommsCore.Calls do\n"
                "  def run(value), do: CommsCore.Alpha.run(value)\n"
                "end\n",
                encoding="utf-8",
            )
            violations = write_current_baseline(root)
            self.assertEqual(
                [item.rule for item in violations],
                ["business_context_cycle"],
            )
            self.declare_current_baseline_deferrals(root)

            manifest = read_yaml(manifest_path)
            manifest["enforcement"]["mode"] = "strict_with_explicit_deferrals"
            manifest["enforcement"]["target_mode"] = "strict_with_explicit_deferrals"
            manifest["enforcement"]["strict_with_explicit_deferrals"] = {
                "active": True,
                "exact_mapping": True,
                "reject_missing_declarations": True,
                "reject_stale_declarations": True,
                "reject_duplicate_fingerprints": True,
                "require_base_branch_no_growth": True,
                "require_deterministic_report": True,
                "allowed_deferral_contexts": ["calls"],
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "contains an independent residual cycle outside "
                    "allowed_deferral_contexts"
                    in error
                    and "alpha <-> beta" in error
                    for error in errors
                ),
                errors,
            )

            retained = violations[0]
            calls_driven = type(retained)(
                retained.rule,
                retained.path,
                "members: alpha, beta, calls; "
                "edges: alpha->calls, beta->alpha, calls->beta",
            )
            manifest = read_yaml(manifest_path)
            self.assertIsNone(
                strict_deferral_rejection_reason(
                    root,
                    manifest,
                    calls_driven,
                    {"calls"},
                )
            )

    def test_validates_runtime_collaboration_and_reports_all_graphs(self) -> None:
        with self.runtime_collaboration_fixture() as root:
            self.assertEqual(validate(root), [])
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            graphs = context_graphs(root, manifest)
            self.assertEqual(graphs.compiled["beta"], frozenset({"alpha"}))
            self.assertEqual(graphs.runtime["alpha"], frozenset({"beta"}))
            self.assertEqual(graphs.combined["alpha"], frozenset({"beta"}))
            self.assertEqual(graphs.combined["beta"], frozenset({"alpha"}))
            self.assertEqual(
                context_cycle_violations(graphs.runtime, "runtime_context_cycle"),
                [],
            )
            runtime_cycle = {
                "alpha": frozenset({"beta"}),
                "beta": frozenset({"alpha"}),
            }
            violations = context_cycle_violations(
                runtime_cycle,
                "runtime_context_cycle",
            )
            self.assertEqual(len(violations), 1)
            self.assertEqual(violations[0].rule, "runtime_context_cycle")
            self.assertIn("alpha->beta", violations[0].detail)
            self.assertIn("beta->alpha", violations[0].detail)

    def test_runtime_collaboration_observes_static_and_delegated_callers(
        self,
    ) -> None:
        callers = (
            ("  alias CommsCore.Alpha.Port\n  defdelegate execute(result), to: Port\n"),
            (
                "  alias CommsCore.Alpha.Port\n"
                "  @port Port\n"
                "  def run(result), do: @port.execute(result)\n"
            ),
        )
        for caller_body in callers:
            with (
                self.subTest(caller_body=caller_body),
                self.runtime_collaboration_fixture() as root,
            ):
                caller = root / "apps/comms_core/lib/comms_core/alpha.ex"
                caller.write_text(
                    f"defmodule CommsCore.Alpha do\n{caller_body}end\n",
                    encoding="utf-8",
                )

                self.assertEqual(validate(root), [])

    def test_runtime_collaboration_rejects_released_adapter_callers(self) -> None:
        with self.runtime_collaboration_fixture() as root:
            caller = root / "apps/comms_web/lib/comms_web/illegal_runtime_caller.ex"
            caller.parent.mkdir(parents=True, exist_ok=True)
            caller.write_text(
                "defmodule CommsWeb.IllegalRuntimeCaller do\n"
                "  alias CommsCore.Alpha.Port\n"
                "  def execute(result), do: Port.execute(result)\n"
                "end\n",
                encoding="utf-8",
            )

            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            violations = [
                item
                for item in analyze_context_boundaries(root, manifest)
                if item.rule == "invalid_runtime_collaboration"
            ]
            self.assertTrue(
                any(
                    "caller set differs from source" in item.detail
                    and "CommsWeb.IllegalRuntimeCaller" in item.detail
                    for item in violations
                ),
                [item.render() for item in violations],
            )

    def test_runtime_collaboration_rejects_implementation_callback_bypasses(
        self,
    ) -> None:
        bypasses = (
            "  alias CommsCore.Beta\n  def run(result), do: Beta.execute(result)\n",
            "  alias CommsCore.Beta\n"
            "  def run(result), do: apply(Beta, :execute, [result])\n",
            "  alias CommsCore.Beta\n"
            "  @implementation Beta\n"
            "  def run(result), "
            "do: apply(@implementation, :execute, [result])\n",
            "  alias CommsCore.Beta\n"
            "  def run(result) do\n"
            "    target = Beta\n"
            "    apply(target, :execute, [result])\n"
            "  end\n",
            "  alias CommsCore.Beta\n  def callback, do: &Beta.execute/1\n",
            "  alias CommsCore.Beta\n"
            "  defdelegate run(result), to: Beta, as: :execute\n",
            "  alias CommsCore.Beta\n  def run(result), do: Beta.execute result\n",
        )
        for bypass in bypasses:
            with (
                self.subTest(bypass=bypass),
                self.runtime_collaboration_fixture() as root,
            ):
                caller = root / "apps/comms_web/lib/comms_web/illegal_impl_caller.ex"
                caller.parent.mkdir(parents=True, exist_ok=True)
                caller.write_text(
                    f"defmodule CommsWeb.IllegalImplCaller do\n{bypass}end\n",
                    encoding="utf-8",
                )

                manifest = read_yaml(
                    root / "docs/02-architecture/context-boundaries.yaml"
                )
                violations = analyze_context_boundaries(root, manifest)
                self.assertTrue(
                    any(
                        item.rule == "invalid_runtime_collaboration"
                        and "CommsWeb.IllegalImplCaller bypasses port "
                        "CommsCore.Alpha.Port"
                        in item.detail
                        and "invoking implementation callbacks" in item.detail
                        for item in violations
                    ),
                    [item.render() for item in violations],
                )

    def test_rejects_runtime_operation_caller_binding_and_transaction_drift(
        self,
    ) -> None:
        mutations = (
            (
                "operations",
                lambda item: item.update(operations=[{"name": "execute", "arity": 2}]),
            ),
            ("callers", lambda item: item.update(callers=["CommsCore.Alpha.Other"])),
            ("binding", lambda item: item["binding"].update(key="wrong_adapter")),
            ("transaction", lambda item: item.update(transaction="eventual")),
        )
        for label, mutate in mutations:
            with (
                self.subTest(label=label),
                self.runtime_collaboration_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                mutate(manifest["runtime_collaborations"][0])
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any("[invalid_runtime_collaboration]" in error for error in errors),
                    errors,
                )

    def test_runtime_graph_semantics_are_exact_not_decorative(self) -> None:
        mutations = (
            lambda semantics: semantics.update(control_flow="arbitrary"),
            lambda semantics: semantics.update(compile_dependency="arbitrary"),
            lambda semantics: semantics.update(static_cycle_policy="documented"),
            lambda semantics: semantics.update(extra_policy="ignored"),
        )
        for mutate in mutations:
            with (
                self.subTest(mutation=mutate),
                self.runtime_collaboration_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                mutate(manifest["runtime_collaborations"][0]["graph_semantics"])
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any(
                        "[invalid_runtime_collaboration]" in error
                        and "graph_semantics must exactly equal" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_accepts_each_guarded_runtime_operation_and_literal_error_clause(
        self,
    ) -> None:
        with self.runtime_collaboration_fixture() as root:
            port_path = root / "apps/comms_core/lib/comms_core/alpha/port.ex"
            port_text = port_path.read_text(encoding="utf-8")
            port_text = port_text.replace(
                "  @callback execute(Result.t()) :: {:ok, Result.t()}\n",
                "  @callback execute(Result.t()) :: {:ok, Result.t()}\n"
                "  @callback fetch(Result.t()) :: {:ok, Result.t()}\n",
            )
            port_head, port_end = port_text.rsplit("end\n", 1)
            port_text = (
                port_head + "  def fetch(%Result{} = result) do\n"
                "    if Repo.in_transaction?() do\n"
                "      {:ok, adapter} = "
                "Application.fetch_env(:comms_core, :alpha_beta_adapter)\n"
                "      adapter.fetch(result)\n"
                "    else\n"
                "      {:error, :transaction_required}\n"
                "    end\n"
                "  end\n"
                "\n"
                "  def fetch(_invalid), do: {:error, :invalid_result}\n"
                "end\n" + port_end
            )
            port_path.write_text(port_text, encoding="utf-8")

            implementation = root / "apps/comms_core/lib/comms_core/beta.ex"
            implementation_text = implementation.read_text(encoding="utf-8")
            implementation_head, implementation_end = implementation_text.rsplit(
                "end\n",
                1,
            )
            implementation.write_text(
                implementation_head + "  def fetch(result), do: {:ok, result}\n"
                "end\n" + implementation_end,
                encoding="utf-8",
            )

            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["runtime_collaborations"][0]["operations"].append(
                {"name": "fetch", "arity": 1}
            )
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            self.assertEqual(validate(root), [])

    def test_rejects_unused_transaction_check_spoof_in_runtime_operation(
        self,
    ) -> None:
        with self.runtime_collaboration_fixture() as root:
            port_path = root / "apps/comms_core/lib/comms_core/alpha/port.ex"
            port_text = port_path.read_text(encoding="utf-8")
            guarded = (
                "    if Repo.in_transaction?() do\n"
                "      {:ok, adapter} = "
                "Application.fetch_env(:comms_core, :alpha_beta_adapter)\n"
                "      adapter.execute(result)\n"
                "    else\n"
                "      {:error, :transaction_required}\n"
                "    end\n"
            )
            spoofed = (
                "    _unused = Repo.in_transaction?()\n"
                "    {:ok, adapter} = "
                "Application.fetch_env(:comms_core, :alpha_beta_adapter)\n"
                "    adapter.execute(result)\n"
            )
            self.assertIn(guarded, port_text)
            port_path.write_text(
                port_text.replace(guarded, spoofed),
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "[invalid_runtime_collaboration]" in error
                    and "execute/1 clause 1 is not wrapped" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_fake_repo_transaction_guard_alias(self) -> None:
        with self.runtime_collaboration_fixture() as root:
            port_path = root / "apps/comms_core/lib/comms_core/alpha/port.ex"
            port_path.write_text(
                port_path.read_text(encoding="utf-8").replace(
                    "alias CommsCore.Repo",
                    "alias CommsCore.Alpha.FakeRepo, as: Repo",
                ),
                encoding="utf-8",
            )
            fake_repo = root / "apps/comms_core/lib/comms_core/alpha/fake_repo.ex"
            fake_repo.write_text(
                "defmodule CommsCore.Alpha.FakeRepo do\n"
                "  def in_transaction?, do: true\n"
                "end\n",
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any(
                    "[invalid_runtime_collaboration]" in error
                    and "execute/1 clause 1 is not wrapped" in error
                    for error in errors
                ),
                errors,
            )

    def test_runtime_contract_roles_must_match_resolved_owners(self) -> None:
        mutations = (
            ("port", "CommsCore.Alpha.Port"),
            ("result", "CommsCore.Alpha.Result"),
            ("implementation", "CommsCore.Beta"),
        )
        for label, module in mutations:
            with (
                self.subTest(label=label),
                self.runtime_collaboration_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                wrong_context = "beta" if label != "implementation" else "alpha"
                manifest["contexts"][wrong_context]["owned_modules"] = [module]
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any(
                        "[invalid_runtime_collaboration]" in error
                        and "belongs to" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_detects_undeclared_cross_owner_runtime_binding(self) -> None:
        with self.runtime_collaboration_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["runtime_collaborations"] = []
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any("[undeclared_runtime_binding]" in error for error in errors),
                errors,
            )

    def test_detects_three_argument_config_runtime_binding(self) -> None:
        with self.runtime_collaboration_fixture() as root:
            config = root / "config/config.exs"
            config.write_text(
                "import Config\n"
                "config :comms_core, :alpha_beta_adapter, CommsCore.Beta\n",
                encoding="utf-8",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["runtime_collaborations"] = []
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            errors = validate(root)
            self.assertTrue(
                any("[undeclared_runtime_binding]" in error for error in errors),
                errors,
            )

    def test_rejects_unenforceable_runtime_port_invocations(self) -> None:
        bodies = (
            "  alias CommsCore.Alpha.Port\n"
            "  def run(result), do: apply(Port, :execute, [result])\n",
            "  alias CommsCore.Alpha.Port\n  def callback, do: &Port.execute/1\n",
            "  import CommsCore.Alpha.Port\n  def run(result), do: execute(result)\n",
            "  alias CommsCore.Alpha.Port\n"
            "  def run(result), do: Port.execute result\n",
        )
        for body in bodies:
            with (
                self.subTest(body=body),
                self.runtime_collaboration_fixture() as root,
            ):
                source = root / "apps/comms_core/lib/comms_core/alpha/other.ex"
                source.write_text(
                    "defmodule CommsCore.Alpha.Other do\n" + body + "end\n",
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any(
                        "[invalid_runtime_collaboration]" in error
                        and "unenforceable port invocation" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_rejects_baseline_field_hash_duplicate_and_order_drift(self) -> None:
        mutations = (
            lambda document: document["violations"][0].update(fingerprint="0" * 16),
            lambda document: document["violations"].append(
                dict(document["violations"][0])
            ),
            lambda document: document["violations"].reverse(),
            lambda document: document.update(policy="baseline drift is allowed"),
        )
        for mutate in mutations:
            with (
                self.subTest(mutation=mutate),
                self.boundary_fixture(allow_alpha=("beta",)) as root,
            ):
                self.write_schema(
                    root,
                    "CommsCore.Alpha.Record",
                    "alpha_records",
                    "alpha/record.ex",
                )
                self.write_schema(
                    root,
                    "CommsCore.Beta.Record",
                    "beta_records",
                    "beta/record.ex",
                )
                for name in ("one", "two"):
                    path = root / f"apps/comms_core/lib/comms_core/alpha/{name}.ex"
                    path.write_text(
                        f"defmodule CommsCore.Alpha.{name.title()} do\n"
                        "  alias CommsCore.Beta.Record\n"
                        "end\n",
                        encoding="utf-8",
                    )
                write_current_baseline(root)
                baseline_path = (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                )
                document = read_yaml(baseline_path)
                mutate(document)
                baseline_path.write_text(
                    yaml.safe_dump(document, sort_keys=False),
                    encoding="utf-8",
                )
                self.assertTrue(
                    any(
                        "BASELINE integrity violation:" in error
                        for error in validate(root)
                    )
                )

    def test_requires_exact_temporary_violation_mapping(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            write_current_baseline(root)
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["temporary_violations"] = {
                "source": "docs/02-architecture/context-boundary-baseline.yaml",
                "exact_mapping": {"cardinality": "one_to_one"},
                "removal_conditions": {
                    "foreign_schema_import": "Use the owner facade."
                },
                "explicit": [],
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any(
                    "must map to exactly one temporary violation" in error
                    for error in errors
                ),
                errors,
            )
            manifest.pop("temporary_violations")
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any("temporary_violations is required" in error for error in errors),
                errors,
            )

    def test_temporary_exact_mapping_policy_rejects_value_and_key_drift(self) -> None:
        mutations = (
            lambda policy: policy.update(cardinality="one_to_one"),
            lambda policy: policy.update(activation_mode="report_only"),
            lambda policy: policy.update(reject_stale_declarations=False),
            lambda policy: policy.update(decorative_policy="accepted"),
            lambda policy: policy.pop("group_policy"),
        )
        for mutate in mutations:
            with (
                self.subTest(mutation=mutate),
                self.repository_fixture() as root,
            ):
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                exact_mapping = copy.deepcopy(TEMPORARY_EXACT_MAPPING_POLICY)
                mutate(exact_mapping)
                manifest["temporary_violations"] = {
                    "source": "docs/02-architecture/context-boundary-baseline.yaml",
                    "exact_mapping": exact_mapping,
                    "removal_conditions": {},
                    "explicit": [],
                }
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any(
                        "exact_mapping must exactly match" in error for error in errors
                    ),
                    errors,
                )

    def test_temporary_violation_adrs_are_confined_and_numbered(self) -> None:
        invalid_paths = (
            "docs/02-architecture/adr/README.md",
            "docs/02-architecture/adr/template.md",
            "docs/02-architecture/adr/../9999-outside.md",
            "../9999-outside.md",
        )
        for adr in invalid_paths:
            with (
                self.subTest(adr=adr),
                self.boundary_fixture(allow_alpha=("beta",)) as root,
            ):
                self.write_schema(
                    root,
                    "CommsCore.Alpha.Record",
                    "alpha_records",
                    "alpha/record.ex",
                )
                self.write_schema(
                    root,
                    "CommsCore.Beta.Record",
                    "beta_records",
                    "beta/record.ex",
                )
                reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
                reader.write_text(
                    "defmodule CommsCore.Alpha.Reader do\n"
                    "  alias CommsCore.Beta.Record\n"
                    "end\n",
                    encoding="utf-8",
                )
                write_current_baseline(root)
                self.declare_current_baseline_deferrals(root)
                manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
                manifest = read_yaml(manifest_path)
                manifest["temporary_violations"]["explicit"][0]["adr"] = adr
                manifest_path.write_text(
                    yaml.safe_dump(manifest, sort_keys=False),
                    encoding="utf-8",
                )
                errors = validate(root)
                self.assertTrue(
                    any(
                        "ADR must be a relative path within "
                        "docs/02-architecture/adr matching NNNN-*.md" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_temporary_violation_top_level_ids_are_unique(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            for name in ("first", "second"):
                source = root / f"apps/comms_core/lib/comms_core/alpha/{name}.ex"
                source.write_text(
                    f"defmodule CommsCore.Alpha.{name.title()} do\n"
                    "  alias CommsCore.Beta.Record\n"
                    "end\n",
                    encoding="utf-8",
                )
            write_current_baseline(root)
            self.declare_current_baseline_deferrals(root)
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            declarations = manifest["temporary_violations"]["explicit"]
            self.assertGreaterEqual(len(declarations), 2)
            declarations[1]["id"] = declarations[0]["id"]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any("duplicates top-level id" in error for error in errors),
                errors,
            )

    def test_temporary_violation_adrs_reject_absolute_paths(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            write_current_baseline(root)
            self.declare_current_baseline_deferrals(root)
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["temporary_violations"]["explicit"][0]["adr"] = str(
                (root / "docs/02-architecture/adr/9999-absolute.md").resolve()
            )
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = validate(root)
            self.assertTrue(
                any(
                    "ADR must be a relative path within "
                    "docs/02-architecture/adr matching NNNN-*.md" in error
                    for error in errors
                ),
                errors,
            )

    def test_generated_report_parity_and_base_branch_no_growth(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            write_current_baseline(root)
            self.assertEqual(generated_report_errors(root), [])
            base = root / "base-boundary-baseline.yaml"
            base.write_text(
                (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).read_text(encoding="utf-8"),
                encoding="utf-8",
            )

            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            write_current_baseline(root)
            self.assertTrue(compare_boundary_baselines(root, base))
            report = root / "docs/02-architecture/context-boundary-violations.md"
            report.write_text(
                report.read_text(encoding="utf-8") + "\nmanual drift\n",
                encoding="utf-8",
            )
            self.assertTrue(generated_report_errors(root))

    def test_content_bound_analyzer_adoption_allows_only_exact_discovery_set(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            base = root / "base-boundary-baseline.yaml"
            base.write_bytes(
                (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).read_bytes()
            )

            first = root / "apps/comms_core/lib/comms_core/alpha/first.ex"
            first.write_text(
                "defmodule CommsCore.Alpha.First do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            first_violations = write_current_baseline(root)
            first_fingerprints = sorted(item.fingerprint for item in first_violations)
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest.setdefault("enforcement", {})["baseline_adoption"] = {
                "previous_baseline_sha256": canonical_text_sha256(base),
                "allowed_discovery_fingerprints": first_fingerprints,
                "removal_condition": "Remove after the analyzer baseline lands.",
            }
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            self.assertEqual(compare_boundary_baselines(root, base), [])

            manifest = read_yaml(manifest_path)
            manifest["enforcement"]["baseline_adoption"][
                "allowed_discovery_fingerprints"
            ] = sorted(["0000000000000000", *first_fingerprints])
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any(
                    "stale allowed discovery fingerprints" in error for error in errors
                ),
                errors,
            )

            manifest["enforcement"]["baseline_adoption"][
                "allowed_discovery_fingerprints"
            ] = first_fingerprints
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            second = root / "apps/comms_core/lib/comms_core/alpha/second.ex"
            second.write_text(
                "defmodule CommsCore.Alpha.Second do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            write_current_baseline(root)
            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any("baseline grew" in error for error in errors),
                errors,
            )

    def test_reviewed_baseline_transition_requires_exact_added_and_removed_sets(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            first = root / "apps/comms_core/lib/comms_core/alpha/first.ex"
            first.write_text(
                "defmodule CommsCore.Alpha.First do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            write_current_baseline(root)
            base = root / "base-boundary-baseline.yaml"
            base.write_bytes(
                (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).read_bytes()
            )
            base_fingerprints = {
                entry["fingerprint"] for entry in read_yaml(base).get("violations", [])
            }

            first.unlink()
            second = root / "apps/comms_core/lib/comms_core/alpha/second.ex"
            second.write_text(
                "defmodule CommsCore.Alpha.Second do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            write_current_baseline(root)
            current_fingerprints = {
                entry["fingerprint"]
                for entry in read_yaml(
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).get("violations", [])
            }
            added = sorted(current_fingerprints - base_fingerprints)
            removed = sorted(base_fingerprints - current_fingerprints)
            self.assertTrue(added)
            self.assertTrue(removed)

            adr = "docs/02-architecture/adr/9999-reviewed-transition.md"
            adr_path = root / adr
            adr_path.parent.mkdir(parents=True, exist_ok=True)
            adr_path.write_text("# Reviewed transition\n", encoding="utf-8")
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["enforcement"]["reviewed_baseline_transitions"] = [
                {
                    "id": "replace-first-with-second",
                    "previous_baseline_sha256": canonical_text_sha256(base),
                    "added_fingerprints": added,
                    "removed_fingerprints": removed,
                    "adr": adr,
                    "removal_condition": "Remove after the new baseline lands.",
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            self.assertEqual(compare_boundary_baselines(root, base), [])

            manifest["enforcement"]["reviewed_baseline_transitions"][0][
                "removed_fingerprints"
            ] = []
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any("undeclared removed fingerprints" in error for error in errors),
                errors,
            )

            manifest["enforcement"]["reviewed_baseline_transitions"][0][
                "removed_fingerprints"
            ] = removed
            manifest["enforcement"]["reviewed_baseline_transitions"][0][
                "added_fingerprints"
            ] = sorted([*added, "0000000000000000"])
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any("stale declared added fingerprints" in error for error in errors),
                errors,
            )

    def test_reviewed_transition_cannot_adopt_protected_rule_growth(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            base = root / "base-boundary-baseline.yaml"
            base.write_bytes(
                (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).read_bytes()
            )
            adapter = root / "apps/comms_web/lib/comms_web/schema_leak.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text(
                "defmodule CommsWeb.SchemaLeak do\n"
                "  alias CommsCore.Alpha.Record\n"
                "  def render(%Record{} = record), do: record\n"
                "end\n",
                encoding="utf-8",
            )
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            violations = analyze_context_boundaries(root, manifest)
            self.assertEqual(
                {item.rule for item in violations},
                {"adapter_schema_import"},
            )
            base_document = read_yaml(base)
            current_baseline = (
                root / "docs/02-architecture/context-boundary-baseline.yaml"
            )
            current_baseline.write_text(
                yaml.safe_dump(
                    {
                        "version": 1,
                        "policy": base_document["policy"],
                        "violations": [
                            {
                                "fingerprint": item.fingerprint,
                                "rule": item.rule,
                                "path": item.path,
                                "detail": item.detail,
                            }
                            for item in violations
                        ],
                    },
                    sort_keys=False,
                ),
                encoding="utf-8",
            )
            added = sorted(item.fingerprint for item in violations)
            adr = "docs/02-architecture/adr/9999-protected-transition.md"
            adr_path = root / adr
            adr_path.parent.mkdir(parents=True, exist_ok=True)
            adr_path.write_text("# Protected transition\n", encoding="utf-8")
            manifest["enforcement"]["reviewed_baseline_transitions"] = [
                {
                    "id": "attempt-protected-adoption",
                    "previous_baseline_sha256": canonical_text_sha256(base),
                    "added_fingerprints": added,
                    "removed_fingerprints": [],
                    "adr": adr,
                    "removal_condition": "This must not be adoptable.",
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any(
                    "added a protected no-new-deferral fingerprint" in error
                    and "[adapter_schema_import]" in error
                    for error in errors
                ),
                errors,
            )

    def test_strict_reviewed_transition_cannot_adopt_any_growth(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            base = root / "base-boundary-baseline.yaml"
            base.write_bytes(
                (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).read_bytes()
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            violations = write_current_baseline(root)
            self.assertEqual(
                {item.rule for item in violations},
                {"foreign_schema_import"},
            )
            added = sorted(item.fingerprint for item in violations)
            adr = "docs/02-architecture/adr/9999-strict-transition.md"
            adr_path = root / adr
            adr_path.parent.mkdir(parents=True, exist_ok=True)
            adr_path.write_text("# Strict transition\n", encoding="utf-8")
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["enforcement"]["mode"] = "strict_with_explicit_deferrals"
            manifest["enforcement"]["target_mode"] = "strict_with_explicit_deferrals"
            manifest["enforcement"]["reviewed_baseline_transitions"] = [
                {
                    "id": "attempt-strict-adoption",
                    "previous_baseline_sha256": canonical_text_sha256(base),
                    "added_fingerprints": added,
                    "removed_fingerprints": [],
                    "adr": adr,
                    "removal_condition": "Strict debt may only shrink.",
                }
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any(
                    "strict boundary baseline may only shrink" in error
                    and "[foreign_schema_import]" in error
                    for error in errors
                ),
                errors,
            )

    def test_activated_strict_gate_cannot_downgrade_mode_and_target(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            base = root / "base-boundary-baseline.yaml"
            base.write_bytes(
                (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).read_bytes()
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            violations = write_current_baseline(root)
            self.assertEqual(
                {item.rule for item in violations},
                {"foreign_schema_import"},
            )
            self.declare_current_baseline_deferrals(root)
            added = sorted(item.fingerprint for item in violations)
            adr = "docs/02-architecture/adr/9999-downgrade-attempt.md"
            adr_path = root / adr
            adr_path.parent.mkdir(parents=True, exist_ok=True)
            adr_path.write_text("# Downgrade attempt\n", encoding="utf-8")
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            manifest["status"] = "enforced"
            manifest["enforcement"].update(
                {
                    "mode": "baseline",
                    "target_mode": "baseline",
                    "strict_with_explicit_deferrals": {
                        "active": True,
                        "exact_mapping": True,
                        "reject_missing_declarations": True,
                        "reject_stale_declarations": True,
                        "reject_duplicate_fingerprints": True,
                        "require_base_branch_no_growth": True,
                        "require_deterministic_report": True,
                        "allowed_deferral_contexts": ["alpha"],
                    },
                    "reviewed_baseline_transitions": [
                        {
                            "id": "attempt-gate-downgrade",
                            "previous_baseline_sha256": canonical_text_sha256(base),
                            "added_fingerprints": added,
                            "removed_fingerprints": [],
                            "adr": adr,
                            "removal_condition": (
                                "The activated strict gate must reject this."
                            ),
                        }
                    ],
                }
            )
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )

            validation_errors = validate(root)
            comparison_errors = compare_boundary_baselines(root, base)
            for errors in (validation_errors, comparison_errors):
                self.assertTrue(
                    any(
                        "activated enforcement target_mode is locked to "
                        "'strict_with_explicit_deferrals'" in error
                        for error in errors
                    ),
                    errors,
                )

    def test_base_manifest_strict_activation_cannot_be_erased(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            base_manifest_path = root / "base-context-boundaries.yaml"
            base_manifest = read_yaml(manifest_path)
            base_manifest["status"] = "enforced"
            base_manifest["enforcement"].update(
                {
                    "mode": "strict_with_explicit_deferrals",
                    "target_mode": "strict_with_explicit_deferrals",
                    "strict_with_explicit_deferrals": {
                        "active": True,
                    },
                }
            )
            base_manifest_path.write_text(
                yaml.safe_dump(base_manifest, sort_keys=False),
                encoding="utf-8",
            )

            weakened = copy.deepcopy(base_manifest)
            weakened.pop("status")
            weakened["enforcement"]["mode"] = "baseline"
            weakened["enforcement"].pop("target_mode")
            weakened["enforcement"].pop("strict_with_explicit_deferrals")
            manifest_path.write_text(
                yaml.safe_dump(weakened, sort_keys=False),
                encoding="utf-8",
            )

            errors = compare_boundary_manifests(root, base_manifest_path)
            self.assertTrue(
                any("immutable base status" in error for error in errors),
                errors,
            )
            self.assertTrue(
                any("immutable base target_mode" in error for error in errors),
                errors,
            )
            self.assertTrue(
                any("downgraded immutable base mode" in error for error in errors),
                errors,
            )
            self.assertTrue(
                any("immutable base strict activation" in error for error in errors),
                errors,
            )

    def test_base_manifest_allows_planned_strict_activation(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            base_manifest_path = root / "base-context-boundaries.yaml"
            base_manifest = read_yaml(manifest_path)
            base_manifest["status"] = "enforced"
            base_manifest["enforcement"].update(
                {
                    "mode": "baseline",
                    "target_mode": "strict_with_explicit_deferrals",
                    "strict_with_explicit_deferrals": {
                        "active": False,
                    },
                }
            )
            base_manifest_path.write_text(
                yaml.safe_dump(base_manifest, sort_keys=False),
                encoding="utf-8",
            )

            activated = copy.deepcopy(base_manifest)
            activated["enforcement"]["mode"] = "strict_with_explicit_deferrals"
            activated["enforcement"]["strict_with_explicit_deferrals"] = {
                "active": True,
            }
            manifest_path.write_text(
                yaml.safe_dump(activated, sort_keys=False),
                encoding="utf-8",
            )

            self.assertEqual(
                compare_boundary_manifests(root, base_manifest_path),
                [],
            )

    def test_base_manifest_allows_strict_promotion_only_after_cleanup(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            for context in ("alpha", "beta"):
                facade = root / f"apps/comms_core/lib/comms_core/{context}.ex"
                facade.write_text(
                    f"defmodule CommsCore.{context.title()} do\nend\n",
                    encoding="utf-8",
                )

            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            base_manifest_path = root / "base-context-boundaries.yaml"
            base_manifest = read_yaml(manifest_path)
            base_manifest["status"] = "enforced"
            base_manifest["enforcement"].update(
                {
                    "mode": "strict_with_explicit_deferrals",
                    "target_mode": "strict_with_explicit_deferrals",
                    "strict_with_explicit_deferrals": {
                        "active": True,
                        "exact_mapping": True,
                        "reject_missing_declarations": True,
                        "reject_stale_declarations": True,
                        "reject_duplicate_fingerprints": True,
                        "require_base_branch_no_growth": True,
                        "require_deterministic_report": True,
                        "allowed_deferral_contexts": ["alpha"],
                    },
                }
            )
            base_manifest_path.write_text(
                yaml.safe_dump(base_manifest, sort_keys=False),
                encoding="utf-8",
            )

            promoted = copy.deepcopy(base_manifest)
            promoted["enforcement"]["mode"] = "strict"
            promoted["enforcement"]["target_mode"] = "strict"
            promoted["enforcement"].pop("strict_with_explicit_deferrals")
            manifest_path.write_text(
                yaml.safe_dump(promoted, sort_keys=False),
                encoding="utf-8",
            )

            self.assertEqual(
                compare_boundary_manifests(root, base_manifest_path),
                [],
            )
            self.assertEqual(validate(root), [])

            stale_variants = (
                (
                    "temporary_violations",
                    lambda document: document.update(temporary_violations={}),
                    "temporary_violations to be removed",
                ),
                (
                    "baseline_adoption",
                    lambda document: document["enforcement"].update(
                        baseline_adoption={}
                    ),
                    "baseline_adoption declaration to be removed",
                ),
                (
                    "strict_policy",
                    lambda document: document["enforcement"].update(
                        strict_with_explicit_deferrals={}
                    ),
                    "strict_with_explicit_deferrals policy to be removed",
                ),
            )
            for label, mutate, expected_error in stale_variants:
                with self.subTest(stale_artifact=label):
                    stale = copy.deepcopy(promoted)
                    mutate(stale)
                    manifest_path.write_text(
                        yaml.safe_dump(stale, sort_keys=False),
                        encoding="utf-8",
                    )
                    errors = validate(root)
                    self.assertTrue(
                        any(expected_error in error for error in errors),
                        errors,
                    )

            manifest_path.write_text(
                yaml.safe_dump(promoted, sort_keys=False),
                encoding="utf-8",
            )
            leak = root / "apps/comms_core/lib/comms_core/alpha/leak.ex"
            leak.write_text(
                "defmodule CommsCore.Alpha.Leak do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            violations = analyze_context_boundaries(root, promoted)
            self.assertTrue(violations)
            write_baseline(root, violations)
            leak.unlink()
            errors = validate(root)
            self.assertTrue(
                any(
                    "strict mode requires an empty boundary baseline" in error
                    for error in errors
                ),
                errors,
            )

    def test_retired_module_and_binding_tombstones_are_immutable(self) -> None:
        with self.boundary_fixture() as root:
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            base_manifest_path = root / "base-context-boundaries.yaml"
            base_manifest = read_yaml(manifest_path)
            base_manifest["retired_modules"] = ["CommsCore.Legacy"]
            base_manifest["retired_runtime_bindings"] = [
                {
                    "application": "comms_core",
                    "key": "authorization_adapter",
                }
            ]
            base_manifest_path.write_text(
                yaml.safe_dump(base_manifest, sort_keys=False),
                encoding="utf-8",
            )

            weakened = copy.deepcopy(base_manifest)
            weakened["retired_modules"] = []
            weakened["retired_runtime_bindings"] = []
            manifest_path.write_text(
                yaml.safe_dump(weakened, sort_keys=False),
                encoding="utf-8",
            )
            errors = compare_boundary_manifests(root, base_manifest_path)
            self.assertTrue(
                any(
                    "removed immutable retired module namespace tombstones" in error
                    for error in errors
                ),
                errors,
            )
            self.assertTrue(
                any(
                    "removed immutable retired runtime binding tombstones" in error
                    for error in errors
                ),
                errors,
            )

            strengthened = copy.deepcopy(base_manifest)
            strengthened["retired_modules"].append("CommsCore.Obsolete")
            strengthened["retired_runtime_bindings"].append(
                {
                    "application": "comms_core",
                    "key": "legacy_adapter",
                }
            )
            manifest_path.write_text(
                yaml.safe_dump(strengthened, sort_keys=False),
                encoding="utf-8",
            )
            self.assertEqual(
                compare_boundary_manifests(root, base_manifest_path),
                [],
            )

    def test_baseline_transition_hash_is_line_ending_independent(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            lf_baseline = root / "baseline-lf.yaml"
            crlf_baseline = root / "baseline-crlf.yaml"
            content = "version: 1\nviolations:\n- fingerprint: abcdef0123456789\n"

            lf_baseline.write_bytes(content.encode("utf-8"))
            crlf_baseline.write_bytes(content.replace("\n", "\r\n").encode("utf-8"))

            self.assertEqual(
                canonical_text_sha256(lf_baseline),
                canonical_text_sha256(crlf_baseline),
            )

    def test_reviewed_baseline_transition_rejects_wrong_or_duplicate_base_hash(
        self,
    ) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            base = root / "base-boundary-baseline.yaml"
            base.write_bytes(
                (
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).read_bytes()
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            write_current_baseline(root)
            added = sorted(
                entry["fingerprint"]
                for entry in read_yaml(
                    root / "docs/02-architecture/context-boundary-baseline.yaml"
                ).get("violations", [])
            )
            adr = "docs/02-architecture/adr/9999-reviewed-transition.md"
            adr_path = root / adr
            adr_path.parent.mkdir(parents=True, exist_ok=True)
            adr_path.write_text("# Reviewed transition\n", encoding="utf-8")
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest = read_yaml(manifest_path)
            transition = {
                "id": "wrong-base",
                "previous_baseline_sha256": "0" * 64,
                "added_fingerprints": added,
                "removed_fingerprints": [],
                "adr": adr,
                "removal_condition": "Remove after the new baseline lands.",
            }
            manifest["enforcement"]["reviewed_baseline_transitions"] = [transition]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any("baseline grew" in error for error in errors),
                errors,
            )

            base_hash = canonical_text_sha256(base)
            first_transition = {
                **transition,
                "id": "first",
                "previous_baseline_sha256": base_hash,
            }
            second_transition = {
                **transition,
                "id": "second",
                "previous_baseline_sha256": base_hash,
            }
            manifest["enforcement"]["reviewed_baseline_transitions"] = [
                first_transition,
                second_transition,
            ]
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            errors = compare_boundary_baselines(root, base)
            self.assertTrue(
                any("previous_baseline_sha256 duplicates" in error for error in errors),
                errors,
            )

    def test_ci_cli_report_and_baseline_comparison_modes(self) -> None:
        with self.runtime_collaboration_fixture() as root:
            baseline = root / "docs/02-architecture/context-boundary-baseline.yaml"
            manifest = root / "docs/02-architecture/context-boundaries.yaml"
            main(["--check-generated-report"], root=root)
            main(
                [
                    "--compare-boundary-baseline",
                    str(baseline),
                    "--compare-boundary-manifest",
                    str(manifest),
                ],
                root=root,
            )

    def test_refuses_new_adapter_schema_deferrals(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            adapter = root / "apps/comms_web/lib/comms_web/presenter.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text(
                "alias CommsCore.Alpha.Record\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                ValueError,
                "refusing to add new deferrals",
            ):
                write_current_baseline(root)

    def test_baseline_allows_existing_fingerprints_but_rejects_new_ones(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex"
            )
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            write_baseline(root, analyze_context_boundaries(root, manifest))
            self.declare_current_baseline_deferrals(root)
            self.assertEqual(validate(root), [])

            second = root / "apps/comms_core/lib/comms_core/alpha/unsafe.ex"
            second.parent.mkdir(parents=True, exist_ok=True)
            second.write_text(
                "defmodule CommsCore.Alpha.Unsafe do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            self.assertTrue(
                any(
                    "NEW context-boundary violation" in error
                    for error in validate(root)
                )
            )

    def test_rejects_resolved_fingerprints_left_in_the_baseline(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex"
            )
            self.write_schema(
                root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex"
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            write_baseline(root, analyze_context_boundaries(root, manifest))
            self.declare_current_baseline_deferrals(root)
            self.assertEqual(validate(root), [])

            reader.unlink()
            self.assertTrue(
                any(
                    error.startswith(
                        "RESOLVED context-boundary baseline fingerprint must be removed:"
                    )
                    for error in validate(root)
                )
            )

    def test_baseline_writer_accepts_intended_baselinable_deltas(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            self.write_schema(
                root,
                "CommsCore.Beta.Record",
                "beta_records",
                "beta/record.ex",
            )
            reader = root / "apps/comms_core/lib/comms_core/alpha/reader.ex"
            reader.write_text(
                "defmodule CommsCore.Alpha.Reader do\n"
                "  alias CommsCore.Beta.Record\n"
                "end\n",
                encoding="utf-8",
            )

            self.assertTrue(
                any(
                    "NEW context-boundary violation" in error
                    for error in validate(root)
                )
            )
            first = write_current_baseline(root)
            self.assertTrue(any(item.rule == "foreign_schema_import" for item in first))
            self.declare_current_baseline_deferrals(root)
            self.assertEqual(validate(root), [])

            reader.unlink()
            self.assertTrue(
                any(
                    error.startswith(
                        "RESOLVED context-boundary baseline fingerprint "
                        "must be removed:"
                    )
                    for error in validate(root)
                )
            )
            second = write_current_baseline(root)
            self.assertFalse(
                any(item.rule == "foreign_schema_import" for item in second)
            )
            self.declare_current_baseline_deferrals(root)
            self.assertEqual(validate(root), [])

    def repository_fixture(self):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)

        for app, dependencies in ALLOWED_UMBRELLA_DEPENDENCIES.items():
            self.write_mix(root, app, tuple(sorted(dependencies)))

        for path in REPO_ACCESS_ALLOWLIST:
            source = root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("alias CommsCore.Repo\n", encoding="utf-8")

        manifest = root / "docs/02-architecture/context-boundaries.yaml"
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(
            yaml.safe_dump(
                {
                    "version": 1,
                    "contexts": {},
                    "tables": {},
                    "technical_interfaces": [],
                    "migration_exceptions": [],
                    "enforcement": {
                        "mode": "baseline",
                        "reject_new_violations": True,
                    },
                },
                sort_keys=False,
            ),
            encoding="utf-8",
        )
        write_baseline(root, [])

        class FixtureContext:
            def __enter__(self):
                return root

            def __exit__(self, exc_type, exc_value, traceback):
                temporary.cleanup()

        return FixtureContext()

    def boundary_fixture(
        self,
        *,
        allow_alpha: tuple[str, ...] = (),
        allow_beta: tuple[str, ...] = (),
    ):
        parent = self.repository_fixture()
        root = parent.__enter__()
        manifest = {
            "version": 1,
            "contexts": {
                "alpha": {
                    "public_facades": ["CommsCore.Alpha"],
                    "public_contracts": [],
                    "internal_namespaces": ["CommsCore.Alpha"],
                    "allowed_dependencies": list(allow_alpha),
                },
                "beta": {
                    "public_facades": ["CommsCore.Beta"],
                    "public_contracts": [],
                    "internal_namespaces": ["CommsCore.Beta"],
                    "allowed_dependencies": list(allow_beta),
                },
            },
            "tables": {
                "alpha_records": {
                    "owner": "alpha",
                    "canonical_schema": "CommsCore.Alpha.Record",
                    "access": "owner_only",
                    "access_namespaces": ["CommsCore.Alpha"],
                },
                "beta_records": {
                    "owner": "beta",
                    "canonical_schema": "CommsCore.Beta.Record",
                    "access": "owner_only",
                    "access_namespaces": ["CommsCore.Beta"],
                },
            },
            "technical_interfaces": [],
            "migration_exceptions": [],
            "enforcement": {
                "mode": "baseline",
                "reject_new_violations": True,
            },
        }
        path = root / "docs/02-architecture/context-boundaries.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8")
        for context in ("alpha", "beta"):
            facade = root / f"apps/comms_core/lib/comms_core/{context}.ex"
            facade.parent.mkdir(parents=True, exist_ok=True)
            facade.write_text(
                f"defmodule CommsCore.{context.title()} do\nend\n",
                encoding="utf-8",
            )

        class FixtureContext:
            def __enter__(self):
                return root

            def __exit__(self, exc_type, exc_value, traceback):
                parent.__exit__(exc_type, exc_value, traceback)

        return FixtureContext()

    def technical_interface_fixture(self):
        parent = self.boundary_fixture()
        root = parent.__enter__()
        self.write_schema(
            root,
            "CommsCore.Alpha.Record",
            "alpha_records",
            "alpha/record.ex",
        )
        self.write_schema(
            root,
            "CommsCore.Beta.Record",
            "beta_records",
            "beta/record.ex",
        )

        alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
        alpha.write_text(
            "defmodule CommsCore.Alpha do\n"
            "  alias CommsCore.Alpha.{Dispatcher, Payload}\n"
            '  def run, do: Dispatcher.execute(%Payload{id: "fixture"})\n'
            "end\n",
            encoding="utf-8",
        )
        dispatcher = root / "apps/comms_core/lib/comms_core/alpha/dispatcher.ex"
        dispatcher.parent.mkdir(parents=True, exist_ok=True)
        dispatcher.write_text(
            "defmodule CommsCore.Alpha.Dispatcher do\n"
            "  alias CommsCore.Alpha.Payload\n"
            "  def execute(%Payload{} = payload) do\n"
            "    implementation = "
            "Application.get_env(:comms_core, :alpha_technical_adapter)\n"
            "    implementation.execute(payload)\n"
            "  end\n"
            "end\n",
            encoding="utf-8",
        )
        contract = root / "apps/comms_core/lib/comms_core/alpha/contract.ex"
        contract.write_text(
            "defmodule CommsCore.Alpha.Contract do\n"
            "  alias CommsCore.Alpha.Payload\n"
            "  @callback execute(Payload.t()) :: :ok\n"
            "end\n",
            encoding="utf-8",
        )
        payload = root / "apps/comms_core/lib/comms_core/alpha/payload.ex"
        payload.write_text(
            "defmodule CommsCore.Alpha.Payload do\n"
            "  @type t :: %__MODULE__{id: binary()}\n"
            "  defstruct [:id]\n"
            "end\n",
            encoding="utf-8",
        )
        implementation = root / "apps/comms_web/lib/comms_web/alpha_adapter.ex"
        implementation.parent.mkdir(parents=True, exist_ok=True)
        implementation.write_text(
            "defmodule CommsWeb.AlphaAdapter do\n"
            "  @behaviour CommsCore.Alpha.Contract\n"
            "  def execute(_payload), do: :ok\n"
            "end\n",
            encoding="utf-8",
        )
        config = root / "config/config.exs"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(
            "import Config\n"
            "config :comms_core,\n"
            "  alpha_technical_adapter: CommsWeb.AlphaAdapter\n",
            encoding="utf-8",
        )

        manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
        manifest = read_yaml(manifest_path)
        manifest["contexts"]["alpha"]["public_contracts"] = [
            "CommsCore.Alpha.Payload",
        ]
        manifest["technical_interfaces"] = [
            {
                "id": "alpha-adapter-notification",
                "owner": "alpha",
                "interface": "CommsCore.Alpha.Dispatcher",
                "callers": ["CommsCore.Alpha"],
                "operations": [{"name": "execute", "arity": 1}],
                "dispatch": "configured",
                "contracts": ["CommsCore.Alpha.Payload"],
                "behaviour": "CommsCore.Alpha.Contract",
                "implementation": "CommsWeb.AlphaAdapter",
                "binding": {
                    "application": "comms_core",
                    "key": "alpha_technical_adapter",
                    "module": "CommsWeb.AlphaAdapter",
                },
                "transaction": "independent",
                "condition": "Alpha emits one stable payload through an exact adapter.",
            }
        ]
        manifest_path.write_text(
            yaml.safe_dump(manifest, sort_keys=False),
            encoding="utf-8",
        )
        write_current_baseline(root)

        class FixtureContext:
            def __enter__(self):
                return root

            def __exit__(self, exc_type, exc_value, traceback):
                parent.__exit__(exc_type, exc_value, traceback)

        return FixtureContext()

    def runtime_collaboration_fixture(self):
        parent = self.boundary_fixture(allow_beta=("alpha",))
        root = parent.__enter__()
        self.write_schema(
            root,
            "CommsCore.Alpha.Record",
            "alpha_records",
            "alpha/record.ex",
        )
        self.write_schema(
            root,
            "CommsCore.Beta.Record",
            "beta_records",
            "beta/record.ex",
        )

        alpha = root / "apps/comms_core/lib/comms_core/alpha.ex"
        alpha.write_text(
            "defmodule CommsCore.Alpha do\n"
            "  alias CommsCore.Alpha.Port\n"
            "  def run(result), do: Port.execute(result)\n"
            "end\n",
            encoding="utf-8",
        )
        port = root / "apps/comms_core/lib/comms_core/alpha/port.ex"
        port.write_text(
            "defmodule CommsCore.Alpha.Port do\n"
            "  alias CommsCore.Alpha.Result\n"
            "  alias CommsCore.Repo\n"
            "  @callback execute(Result.t()) :: {:ok, Result.t()}\n"
            "  def execute(%Result{} = result) do\n"
            "    if Repo.in_transaction?() do\n"
            "      {:ok, adapter} = "
            "Application.fetch_env(:comms_core, :alpha_beta_adapter)\n"
            "      adapter.execute(result)\n"
            "    else\n"
            "      {:error, :transaction_required}\n"
            "    end\n"
            "  end\n"
            "end\n",
            encoding="utf-8",
        )
        result = root / "apps/comms_core/lib/comms_core/alpha/result.ex"
        result.write_text(
            "defmodule CommsCore.Alpha.Result do\n"
            "  @type t :: %__MODULE__{id: binary()}\n"
            "  defstruct [:id]\n"
            "end\n",
            encoding="utf-8",
        )
        beta = root / "apps/comms_core/lib/comms_core/beta.ex"
        beta.write_text(
            "defmodule CommsCore.Beta do\n"
            "  @behaviour CommsCore.Alpha.Port\n"
            "  def execute(result), do: {:ok, result}\n"
            "end\n",
            encoding="utf-8",
        )
        config = root / "config/config.exs"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(
            "import Config\n"
            "config :comms_core,\n"
            "  alpha_beta_adapter: CommsCore.Beta\n",
            encoding="utf-8",
        )

        manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
        manifest = read_yaml(manifest_path)
        manifest["contexts"]["alpha"]["public_contracts"] = [
            "CommsCore.Alpha.Port",
            "CommsCore.Alpha.Result",
        ]
        manifest["runtime_collaborations"] = [
            {
                "id": "alpha-beta",
                "consumer": "alpha",
                "provider": "beta",
                "port": "CommsCore.Alpha.Port",
                "result_contract": "CommsCore.Alpha.Result",
                "implementation": "CommsCore.Beta",
                "callers": ["CommsCore.Alpha"],
                "operations": [{"name": "execute", "arity": 1}],
                "binding": {
                    "application": "comms_core",
                    "key": "alpha_beta_adapter",
                    "module": "CommsCore.Beta",
                },
                "transaction": "required",
                "graph_semantics": {
                    "control_flow": "alpha_to_beta",
                    "compile_dependency": "beta_to_alpha",
                    "static_cycle_policy": "dependency_inversion",
                },
                "condition": "Alpha delegates one transaction-scoped operation.",
            }
        ]
        manifest_path.write_text(
            yaml.safe_dump(manifest, sort_keys=False),
            encoding="utf-8",
        )
        write_current_baseline(root)

        class FixtureContext:
            def __enter__(self):
                return root

            def __exit__(self, exc_type, exc_value, traceback):
                parent.__exit__(exc_type, exc_value, traceback)

        return FixtureContext()

    @staticmethod
    def declare_current_baseline_deferrals(root: Path) -> None:
        baseline_path = root / "docs/02-architecture/context-boundary-baseline.yaml"
        baseline = read_yaml(baseline_path)
        entries = baseline.get("violations", [])
        manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
        manifest = read_yaml(manifest_path)
        if not entries:
            manifest.pop("temporary_violations", None)
            manifest_path.write_text(
                yaml.safe_dump(manifest, sort_keys=False),
                encoding="utf-8",
            )
            return

        adr = "docs/02-architecture/adr/9999-test-boundary-debt.md"
        adr_path = root / adr
        adr_path.parent.mkdir(parents=True, exist_ok=True)
        adr_path.write_text("# Test boundary debt\n", encoding="utf-8")
        manifest["temporary_violations"] = {
            "source": "docs/02-architecture/context-boundary-baseline.yaml",
            "exact_mapping": copy.deepcopy(TEMPORARY_EXACT_MAPPING_POLICY),
            "removal_conditions": {
                entry["rule"]: "Remove the fixture violation." for entry in entries
            },
            "explicit": [
                {
                    "id": f"fixture-{entry['fingerprint']}",
                    **entry,
                    "adr": adr,
                    "removal_condition": "Remove the fixture violation.",
                }
                for entry in entries
            ],
        }
        manifest_path.write_text(
            yaml.safe_dump(manifest, sort_keys=False),
            encoding="utf-8",
        )

    @staticmethod
    def write_schema(root: Path, module: str, table: str, relative_source: str) -> None:
        path = root / "apps/comms_core/lib/comms_core" / relative_source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f'defmodule {module} do\n  schema "{table}" do\n  end\nend\n',
            encoding="utf-8",
        )

    @staticmethod
    def assert_rule(root: Path, rule: str) -> None:
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)
        if not any(violation.rule == rule for violation in violations):
            raise AssertionError(
                f"missing rule {rule}; observed: {[item.render() for item in violations]}"
            )

    @staticmethod
    def assert_not_rule(root: Path, rule: str) -> None:
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)
        matching = [item.render() for item in violations if item.rule == rule]
        if matching:
            raise AssertionError(f"unexpected rule {rule}; observed: {matching}")

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
