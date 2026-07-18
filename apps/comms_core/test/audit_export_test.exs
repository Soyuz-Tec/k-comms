defmodule CommsCore.AuditExportTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Audit, AuditExport}
  alias CommsTestSupport.Fixtures

  test "export is step-up and tenant scoped, capped, filterable, and spreadsheet-injection safe" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    other = Fixtures.account_fixture()

    assert {:error, :step_up_required} = AuditExport.export(%{}, subject)
    subject = Fixtures.step_up(account, subject)

    event =
      insert_event(
        account.tenant.id,
        account.user.id,
        "=HYPERLINK(\"https://evil.test\")",
        "+formula",
        "@request"
      )

    _second =
      insert_event(
        account.tenant.id,
        account.user.id,
        "=HYPERLINK(\"https://evil.test\")",
        "-formula",
        "@request-2"
      )

    _foreign = insert_event(other.tenant.id, other.user.id, event.action, "+foreign", "@foreign")

    assert {:ok, export} = AuditExport.export(%{q: "https://evil.test", limit: 1}, subject)
    assert export.count == 1
    assert export.truncated
    assert export.csv =~ "\"'=HYPERLINK(\"\"https://evil.test\"\")\""
    assert export.csv =~ "\"'-formula\"" or export.csv =~ "\"'+formula\""
    refute export.csv =~ "+foreign"
    assert String.starts_with?(export.csv, "\"inserted_at\",\"actor_user_id\"")

    [evidence] =
      Audit.list(%{
        tenant_id: account.tenant.id,
        action: "audit.export",
        resource_id: account.tenant.id,
        limit: 1
      })

    assert evidence.metadata["returned_count"] == 1 or evidence.metadata[:returned_count] == 1
    assert evidence.metadata["truncated"] == true or evidence.metadata[:truncated] == true
    refute inspect(evidence.metadata) =~ "https://evil.test"
  end

  test "structured time and actor filters reject malformed values" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:error, :invalid_datetime} = AuditExport.export(%{after: "yesterday"}, subject)

    assert {:error, :invalid_search_query} =
             AuditExport.export(%{actor_user_id: "not-a-uuid"}, subject)

    assert {:error, :invalid_search_query} =
             AuditExport.export(%{q: String.duplicate("x", 201)}, subject)

    assert {:error, :invalid_search_query} =
             AuditExport.export(%{action: %{unexpected: "shape"}}, subject)
  end

  test "audit export preserves compliance, security, and tenant-admin role separation" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)

    compliance =
      create_login_subject(
        account,
        owner_subject,
        :compliance_admin,
        "audit-compliance@example.test",
        "correct-horse-audit-compliance"
      )

    security =
      create_login_subject(
        account,
        owner_subject,
        :security_admin,
        "audit-security@example.test",
        "correct-horse-audit-security"
      )

    admin =
      create_login_subject(
        account,
        owner_subject,
        :admin,
        "audit-admin@example.test",
        "correct-horse-audit-admin"
      )

    assert {:error, :step_up_required} = AuditExport.export(%{}, compliance.subject)
    assert {:error, :step_up_required} = AuditExport.export(%{}, security.subject)
    assert {:error, :forbidden} = AuditExport.export(%{}, admin.subject)

    assert {:ok, _session} =
             Accounts.step_up(
               %{current_password: compliance.password},
               compliance.subject
             )

    assert {:ok, _session} =
             Accounts.step_up(%{current_password: security.password}, security.subject)

    assert {:ok, _session} =
             Accounts.step_up(%{current_password: admin.password}, admin.subject)

    assert {:ok, _export} = AuditExport.export(%{}, compliance.subject)
    assert {:ok, _export} = AuditExport.export(%{}, security.subject)
    assert {:error, :forbidden} = AuditExport.export(%{}, admin.subject)
  end

  defp insert_event(tenant_id, actor_id, action, resource_type, request_id) do
    {:ok, event} =
      Audit.record(%{
        tenant_id: tenant_id,
        actor_user_id: actor_id,
        action: action,
        resource_type: resource_type,
        resource_id: Ecto.UUID.generate(),
        request_id: request_id,
        metadata: %{note: "tenant evidence"}
      })

    event
  end

  defp create_login_subject(account, owner_subject, role, email, password) do
    assert {:ok, user} =
             Accounts.create_user(
               %{
                 display_name: "Audit export role",
                 email: email,
                 password: password,
                 role: Atom.to_string(role)
               },
               owner_subject
             )

    assert {:ok, authentication} =
             Accounts.authenticate(account.tenant.slug, user.email, password, %{
               name: "Audit export browser",
               platform: "test"
             })

    %{subject: Accounts.subject_for_session(authentication.session), password: password}
  end
end
