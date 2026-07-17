from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

import yaml

from validate_architecture import (
    ALLOWED_UMBRELLA_DEPENDENCIES,
    REPO_ACCESS_ALLOWLIST,
    analyze_context_boundaries,
    core_module_references,
    discover_schemas,
    read_yaml,
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
                any("required boundary manifest is missing" in error for error in validate(root))
            )
            with self.assertRaisesRegex(ValueError, "manifest is missing or invalid"):
                write_current_baseline(root)

    def test_invalid_boundary_manifest_fails_validation_and_baseline_write(
        self,
    ) -> None:
        with self.repository_fixture() as root:
            manifest = root / "docs/02-architecture/context-boundaries.yaml"
            manifest.write_text("contexts: [not-a-mapping\n", encoding="utf-8")

            self.assertTrue(
                any("cannot load boundary manifest" in error for error in validate(root))
            )
            with self.assertRaisesRegex(ValueError, "manifest is missing or invalid"):
                write_current_baseline(root)

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

    def test_parses_grouped_aliases_from_the_comms_core_root(self) -> None:
        references = core_module_references(
            "alias CommsCore.{Accounts, Messaging}\n"
            "alias CommsCore.Administration.{InvitationView}\n"
        )

        self.assertEqual(
            references,
            {
                "CommsCore.Accounts",
                "CommsCore.Messaging",
                "CommsCore.Administration",
                "CommsCore.Administration.InvitationView",
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

    def test_nested_and_chained_schema_aliases_cannot_hide_graph_edges(
        self,
    ) -> None:
        sources = (
            "  alias CommsCore.{Beta.Record}\n",
            "  alias CommsCore.Beta\n"
            "  alias Beta.Record\n",
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
            "defmodule CommsCore.Backdoor do\n"
            "  import CommsCore.Accounts\n"
            "end\n",
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
        )

        for index, source in enumerate(sources):
            with self.subTest(index=index), self.repository_fixture() as root:
                path = (
                    root
                    / f"apps/comms_workers/lib/comms_workers/unsafe_{index}.ex"
                )
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")

                errors = validate(root)
                self.assertTrue(
                    any(
                        "owner-internal lifecycle command" in error
                        for error in errors
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

    def test_rejects_duplicate_table_mappings(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex")
            self.write_schema(root, "CommsCore.Beta.Record", "alpha_records", "beta/record.ex")

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
                if (
                    "oban_jobs" in item.detail or "oban_peers" in item.detail
                )
                and item.rule
                in {"declared_table_missing", "invalid_table_declaration"}
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
                manifest_path = (
                    root / "docs/02-architecture/context-boundaries.yaml"
                )
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
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")

        self.assertEqual(
            schemas["users"],
            [
                (
                    "CommsCore.Accounts.User",
                    "apps/comms_core/lib/comms_core/accounts/user.ex",
                )
            ],
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
                self.assertNotIn("CommsCore.Accounts.User", source)
                for field in required_fields:
                    self.assertIn(field, source)

    def test_repository_routes_message_boundary_work_through_conversations(self) -> None:
        root = Path(__file__).resolve().parents[1]
        source = (
            root / "apps/comms_core/lib/comms_core/messaging.ex"
        ).read_text(encoding="utf-8")
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

    def test_repository_keeps_audit_persistence_inside_the_audit_implementation(self) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        audit_table = manifest["tables"]["audit_events"]

        self.assertEqual(audit_table["access"], "owner_only")
        self.assertEqual(audit_table["access_namespaces"], ["CommsCore.Audit"])
        self.assertEqual(
            manifest["contexts"]["audit"]["public_contracts"],
            ["CommsCore.Audit.Event", "CommsCore.Audit.Error"],
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

    def test_repository_enforces_the_conversation_content_direction_and_contracts(self) -> None:
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
                "CommsCore.Messaging.ReactionView",
                "CommsCore.Attachments.AttachmentView",
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

        for controller in ("service_message_controller.ex", "service_search_controller.ex"):
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
                        adapter_leaks.append((path.relative_to(root).as_posix(), module))
        self.assertEqual(adapter_leaks, [])
        self.assertEqual(
            manifest["tables"]["users"],
            {
                "owner": "identity_access",
                "canonical_schema": "CommsCore.Accounts.User",
                "role": "source",
            },
        )

    def test_repository_consolidates_notification_delivery_behind_one_facade(self) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        delivery = manifest["contexts"]["notification_delivery"]

        self.assertEqual(delivery["current_contexts"], ["Notifications"])
        self.assertEqual(delivery["fold_in"], ["InAppNotifications", "PushSubscriptions"])
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
        self.assertEqual(
            manifest["retired_modules"],
            ["CommsCore.InAppNotifications", "CommsCore.PushSubscriptions"],
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

    def test_repository_inverts_identity_notification_lifecycle_dependency(self) -> None:
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
                "apps/comms_core/lib/comms_core/accounts.ex",
                "apps/comms_core/lib/comms_core/notifications.ex",
                "apps/comms_core/lib/comms_core/password_recovery.ex",
            ],
        )

        port_callers = []
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            if "NotificationPort.execute" in path.read_text(encoding="utf-8"):
                port_callers.append(path.relative_to(root).as_posix())
        self.assertEqual(
            port_callers,
            [
                "apps/comms_core/lib/comms_core/accounts.ex",
                "apps/comms_core/lib/comms_core/password_recovery.ex",
            ],
        )

        adapter_contract_leaks = []
        for app in ("comms_web", "comms_workers", "comms_integrations"):
            for path in sorted((root / f"apps/{app}/lib").rglob("*.ex")):
                references = core_module_references(path.read_text(encoding="utf-8"))
                leaked = sorted(references.intersection(identity_notification_contracts))
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
        self.assertTrue(
            bootstrap_contracts.issubset(set(identity["public_contracts"]))
        )

        self.assertEqual(
            manifest["runtime_collaborations"],
            [
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
                }
            ],
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
            root
            / "apps/comms_core/lib/comms_core/accounts/"
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
            "ServiceAccounts.authorize_service(subject, \"messages:",
            messaging_source,
        )

        controller_source = (
            root
            / "apps/comms_web/lib/comms_web/controllers/"
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
                    owner_api_callers[call].append(
                        path.relative_to(root).as_posix()
                    )
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
        self.assertIn("75826183c4276dbe", current_fingerprints)

        cycle = [item for item in violations if item.rule == "business_context_cycle"]
        self.assertEqual(len(cycle), 1)
        self.assertEqual(cycle[0].fingerprint, "75826183c4276dbe")
        self.assertNotIn("identity_access->conversations", cycle[0].detail)

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
                "CommsCore.AdmissionQuotas.active_user_count/1",
                "CommsCore.AdmissionQuotas.admission_policy/1",
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
            return conversation_source[start:] if end == -1 else conversation_source[start:end]

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
        self.assertIn("AdmissionQuotas.active_user_count(", operations_source)
        self.assertIn("AdmissionQuotas.admission_policy(", operations_source)
        self.assertIn("Conversations.admission_usage(", operations_source)

        projection_callers = {
            "AdmissionQuotas.active_user_count(": [],
            "AdmissionQuotas.admission_policy(": [],
            "Conversations.admission_usage(": [],
        }
        for path in sorted((root / "apps").glob("*/lib/**/*.ex")):
            source = path.read_text(encoding="utf-8")
            for call in projection_callers:
                if call in source:
                    projection_callers[call].append(
                        path.relative_to(root).as_posix()
                    )
        self.assertEqual(
            projection_callers,
            {
                "AdmissionQuotas.active_user_count(": [
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
            root
            / "apps/comms_web/lib/comms_web/controllers/admin_tenant_controller.ex"
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

    def test_repository_keeps_released_adapters_on_declared_public_contracts(self) -> None:
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
            [item.rule for item in violations if item.rule.startswith("public_contract_")],
            [],
        )
        self.assertEqual(
            [item.detail for item in violations if item.rule == "adapter_schema_import"],
            [
                "adapter references internal Ecto schema "
                "CommsCore.AudioCalls.AudioCall"
            ],
        )
        self.assertEqual(
            [item for item in violations if item.rule == "adapter_changeset_import"],
            [],
        )

    def test_rejects_adapter_imports_of_ecto_schemas(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex")
            adapter = root / "apps/comms_web/lib/comms_web/presenter.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text("alias CommsCore.Alpha.Record\n", encoding="utf-8")

            self.assert_rule(root, "adapter_schema_import")

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

    def test_rejects_undeclared_context_edges_and_foreign_writes(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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

    def test_does_not_treat_foreign_reads_plus_owner_writes_as_foreign_writes(
        self,
    ) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
            self.write_schema(root, "CommsCore.Alpha.Tenant", "tenants", "alpha/tenant.ex")
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
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
            source = root / "apps/comms_core/lib/comms_core/alpha.ex"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "defmodule CommsCore.Alpha do\n"
                "  import Ecto.Query\n"
                "  alias CommsCore.Beta.Record\n"
                "  alias CommsCore.Repo\n"
                "  def direct, do: Repo.delete_all(from(record in Record))\n"
                "  def through_variable do\n"
                "    query = from(record in Record, where: record.id == ^\"id\")\n"
                "    Repo.update_all(query, set: [status: :deleted])\n"
                "  end\n"
                "end\n",
                encoding="utf-8",
            )

            self.assert_rule(root, "direct_foreign_write")

    def test_attributes_only_the_root_of_a_joined_bulk_write(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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

    def test_repository_routes_governance_erasure_writes_through_owner_facades(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)
        source = (
            root / "apps/comms_core/lib/comms_core/governance.ex"
        ).read_text(encoding="utf-8")

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

    def test_repository_routes_user_lifecycle_and_retention_reads_one_way(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[1]
        accounts = (
            root / "apps/comms_core/lib/comms_core/accounts.ex"
        ).read_text(encoding="utf-8")
        governance = (
            root / "apps/comms_core/lib/comms_core/governance.ex"
        ).read_text(encoding="utf-8")
        retention_reader = (
            root
            / "apps/comms_core/lib/comms_core/governance/retention_defaults_reader.ex"
        ).read_text(encoding="utf-8")
        controller = (
            root
            / "apps/comms_web/lib/comms_web/controllers/admin_user_controller.ex"
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
        source = (
            root / "apps/comms_core/lib/comms_core/accounts.ex"
        ).read_text(encoding="utf-8")
        manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
        violations = analyze_context_boundaries(root, manifest)

        self.assertIn("Administration.append_bootstrap_tenant", source)
        self.assertIn("ConversationBootstrapPort.append_initial_channel", source)
        self.assertIn("ConversationBootstrapPort.create_initial_channel", source)
        self.assertIn("ConversationBootstrapPort.fetch_initial_channel", source)
        self.assertNotIn("CommsCore.Conversations", source)
        self.assertNotIn("CommsCore.Administration.Invitation", source)
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

    def test_rejects_owner_only_schema_access_across_an_allowed_context_edge(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",)) as root:
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
            self.write_schema(root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex")
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

    def test_public_contract_prefix_does_not_match_an_internal_schema(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex")
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
                {item.rule for item in analyze_context_boundaries(root, read_yaml(root / "docs/02-architecture/context-boundaries.yaml"))},
            )

    def test_rejects_business_context_cycles(self) -> None:
        with self.boundary_fixture(allow_alpha=("beta",), allow_beta=("alpha",)) as root:
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
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.{Beta.Record}\n"
                "end\n",
                encoding="utf-8",
            )
            beta = root / "apps/comms_core/lib/comms_core/beta.ex"
            beta.write_text(
                "defmodule CommsCore.Beta do\n"
                "  alias CommsCore.Alpha\n"
                "end\n",
                encoding="utf-8",
            )

            violations = analyze_context_boundaries(
                root,
                read_yaml(
                    root / "docs/02-architecture/context-boundaries.yaml"
                ),
            )
            cycle = next(
                item
                for item in violations
                if item.rule == "business_context_cycle"
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
                source = (
                    root / f"apps/comms_core/lib/comms_core/alpha/{filename}"
                )
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
                    "non-baselinable read-model control violations",
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
            manifest = read_yaml(
                root / "docs/02-architecture/context-boundaries.yaml"
            )
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
                "non-baselinable read-model control violations",
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
                "defmodule CommsCore.Alpha do\n"
                "  alias CommsCore.{Beta, Gamma}\n"
                "end\n",
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
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
                "defmodule CommsCore.Alpha do\n"
                "  def lookup(id), do: id\n"
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
            "  import CommsCore.Beta\n"
            "  def run(id), do: lookup(id)\n",
            "  alias CommsCore.Beta, as: Directory\n"
            "  import Directory\n"
            "  def run(id), do: lookup(id)\n",
            "  alias CommsCore.Beta\n"
            "  def run(id), do: Beta.lookup id\n",
            "  alias CommsCore.Beta\n"
            "  def run(id), do: apply(Beta, :lookup, [id])\n",
            "  alias CommsCore.Beta\n"
            "  def run(id), do: :erlang.apply(Beta, :lookup, [id])\n",
            "  alias CommsCore.Beta\n"
            "  def run, do: &Beta.delete/1\n",
            "  alias CommsCore.Beta\n"
            "  def run, do: Function.capture(Beta, :delete, 1)\n",
            "  alias CommsCore.Beta\n"
            "  def run(a, b), do: Beta.lookup(a, b)\n",
        )

        for index, unsafe_source in enumerate(unsafe_sources):
            with self.subTest(index=index), self.boundary_fixture(
                allow_alpha=("beta",)
            ) as root:
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
                    "defmodule CommsCore.Alpha do\n"
                    f"{unsafe_source}"
                    "end\n",
                    encoding="utf-8",
                )
                manifest_path = (
                    root / "docs/02-architecture/context-boundaries.yaml"
                )
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
                "defmodule CommsCore.Beta do\n"
                "  def lookup(id), do: id\n"
                "end\n",
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
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
            "  alias Oban, as: Jobs\n"
            "  def mutate(job), do: Jobs.insert(job)\n",
            "  import CommsCore.Repo\n",
            "  alias CommsCore.Repo, as: Database\n"
            "  import Database\n",
            "  def mutate(changeset), do: Repo.update changeset\n",
            "  def mutate(record), do: apply(Repo, :delete, [record])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            "\"UPDATE beta_records SET status = 'closed'\", [])\n",
            "  @mutation \"DELETE FROM beta_records\"\n"
            "  def mutate, do: Ecto.Adapters.SQL.query!(Repo, @mutation, [])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            "\"CREATE INDEX unsafe_idx ON beta_records (id)\", [])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            "\"DROP INDEX unsafe_idx\", [])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            "\"ALTER INDEX unsafe_idx RENAME TO worse_idx\", [])\n",
            "  def mutate(statement), do: "
            "Ecto.Adapters.SQL.query(Repo, statement, [])\n",
            "  def mutate, do: Ecto.Adapters.SQL.query(Repo, "
            "\"VACUUM beta_records\", [])\n",
            "  alias Ecto.Adapters.SQL, as: Database\n"
            "  def mutate(statement), do: Database.query(Repo, statement, [])\n",
            "  import Ecto.Adapters.SQL\n"
            "  def mutate(statement), do: query(Repo, statement, [])\n",
            "  def mutate(statement), do: "
            "apply(Ecto.Adapters.SQL, :query, [Repo, statement, []])\n",
            "  def mutate(statement), do: "
            "Ecto.Adapters.SQL.query Repo, statement, []\n",
            "  alias Ecto.Adapters.SQL, as: Database\n"
            "  import Database\n",
            "  alias Ecto.Adapters.SQL, as: Database\n"
            "  def mutate, do: &Database.query/4\n",
        )

        for index, body in enumerate(unsafe_bodies):
            with self.subTest(index=index), self.boundary_fixture(
                allow_alpha=("beta",)
            ) as root:
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
                manifest_path = (
                    root / "docs/02-architecture/context-boundaries.yaml"
                )
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
                "Repo, \"SELECT id FROM beta_records\", [])\n"
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
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
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
                "invalid_read_model_exception",
                "read_model_scope_violation",
                "read_model_write",
                "read_model_reverse_dependency",
            }
            with self.assertRaisesRegex(
                ValueError,
                "refusing to baseline non-baselinable read-model control violations",
            ):
                write_baseline(root, violations)
            write_baseline(
                root,
                [item for item in violations if item.rule not in control_rules],
            )
            errors = validate(root)
            rendered = "\n".join(errors)
            for rule in control_rules:
                self.assertIn(f"[{rule}]", rendered)
            self.assertTrue(
                all(
                    error.startswith("READ-MODEL control violation:")
                    for error in errors
                ),
                errors,
            )

    def test_baseline_allows_existing_fingerprints_but_rejects_new_ones(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex")
            adapter = root / "apps/comms_web/lib/comms_web/presenter.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text("alias CommsCore.Alpha.Record\n", encoding="utf-8")
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            write_baseline(root, analyze_context_boundaries(root, manifest))
            self.assertEqual(validate(root), [])

            second = root / "apps/comms_workers/lib/comms_workers/unsafe.ex"
            second.parent.mkdir(parents=True, exist_ok=True)
            second.write_text("alias CommsCore.Alpha.Record\n", encoding="utf-8")
            self.assertTrue(
                any("NEW context-boundary violation" in error for error in validate(root))
            )

    def test_rejects_resolved_fingerprints_left_in_the_baseline(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(root, "CommsCore.Alpha.Record", "alpha_records", "alpha/record.ex")
            self.write_schema(root, "CommsCore.Beta.Record", "beta_records", "beta/record.ex")
            adapter = root / "apps/comms_web/lib/comms_web/presenter.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text("alias CommsCore.Alpha.Record\n", encoding="utf-8")
            manifest = read_yaml(root / "docs/02-architecture/context-boundaries.yaml")
            write_baseline(root, analyze_context_boundaries(root, manifest))
            self.assertEqual(validate(root), [])

            adapter.unlink()
            self.assertTrue(
                any(
                    error.startswith(
                        "RESOLVED context-boundary baseline fingerprint must be removed:"
                    )
                    for error in validate(root)
                )
            )

    def test_baseline_writer_accepts_intended_baselinable_deltas(self) -> None:
        with self.boundary_fixture() as root:
            self.write_schema(
                root,
                "CommsCore.Alpha.Record",
                "alpha_records",
                "alpha/record.ex",
            )
            adapter = root / "apps/comms_web/lib/comms_web/presenter.ex"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text(
                "alias CommsCore.Alpha.Record\n", encoding="utf-8"
            )

            self.assertTrue(
                any(
                    "NEW context-boundary violation" in error
                    for error in validate(root)
                )
            )
            first = write_current_baseline(root)
            self.assertTrue(
                any(item.rule == "adapter_schema_import" for item in first)
            )
            self.assertEqual(validate(root), [])

            adapter.unlink()
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
                any(item.rule == "adapter_schema_import" for item in second)
            )
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
                    "migration_exceptions": [],
                },
                sort_keys=False,
            ),
            encoding="utf-8",
        )

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
            "migration_exceptions": [],
        }
        path = root / "docs/02-architecture/context-boundaries.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8")

        class FixtureContext:
            def __enter__(self):
                return root

            def __exit__(self, exc_type, exc_value, traceback):
                parent.__exit__(exc_type, exc_value, traceback)

        return FixtureContext()

    @staticmethod
    def write_schema(
        root: Path, module: str, table: str, relative_source: str
    ) -> None:
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
