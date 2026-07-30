defmodule CommsCore.Administration.AuditQueriesTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration

  alias CommsCore.{Administration, Audit}
  alias CommsCore.Audit.TestSupport
  alias CommsTestSupport.Fixtures

  test "audit reads are audited and compound cursors do not skip equal timestamps" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    rows =
      Enum.map(ids, fn id ->
        %{
          id: id,
          tenant_id: account.tenant.id,
          actor_user_id: account.user.id,
          action: "cursor-test",
          resource_type: "tenant",
          resource_id: account.tenant.id,
          metadata: %{},
          request_id: "cursor-test",
          inserted_at: timestamp
        }
      end)

    assert 2 == rows |> Enum.map(&TestSupport.insert!/1) |> length()

    assert {:ok, first_page} =
             Administration.list_audit_events(%{action: "cursor-test", limit: 1}, subject)

    assert [first] = first_page.events
    assert is_binary(first_page.next_cursor)

    assert {:ok, second_page} =
             Administration.list_audit_events(
               %{action: "cursor-test", limit: 1, cursor: first_page.next_cursor},
               subject
             )

    assert [second] = second_page.events
    refute first.id == second.id

    assert 2 == Audit.count(%{tenant_id: account.tenant.id, action: "audit.read"})
  end
end
