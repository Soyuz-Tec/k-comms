defmodule CommsCore.AuditExportTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{AuditExport, Repo}
  alias CommsCore.Audit.AuditEvent
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

    evidence =
      Repo.one!(
        from(audit in AuditEvent,
          where:
            audit.tenant_id == ^account.tenant.id and audit.action == "audit.export" and
              audit.resource_id == ^account.tenant.id,
          order_by: [desc: audit.inserted_at],
          limit: 1
        )
      )

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

  defp insert_event(tenant_id, actor_id, action, resource_type, request_id) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: tenant_id,
      actor_user_id: actor_id,
      action: action,
      resource_type: resource_type,
      resource_id: Ecto.UUID.generate(),
      request_id: request_id,
      metadata: %{note: "tenant evidence"}
    })
    |> Repo.insert!()
  end
end
