defmodule CommsCore.Administration.AuditQueriesTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration

  alias CommsCore.{Administration, Audit, AuditExport}
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
    assert is_nil(second_page.next_cursor)

    assert 2 == Audit.count(%{tenant_id: account.tenant.id, action: "audit.read"})
  end

  test "search matches export, treats wildcard characters literally and stays tenant scoped" do
    account = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    match = insert_event!(account, %{request_id: "sensitive-%_-needle"})
    insert_event!(account, %{request_id: "sensitive-XX-needle"})
    insert_event!(other, %{request_id: "sensitive-%_-needle"})

    filters = %{q: "  %_  ", action: "  search-test  "}
    assert {:ok, page} = Administration.list_audit_events(filters, subject)
    assert [event] = page.events
    assert event.id == match.id
    assert is_nil(page.next_cursor)

    assert {:ok, export} = AuditExport.export(filters, subject)
    assert export.count == 1
    assert export.csv =~ match.resource_id
    refute export.truncated

    assert [read] = Audit.list(%{tenant_id: account.tenant.id, action: "audit.read"})
    assert read.metadata["query_present"]
    refute Jason.encode!(read.metadata) =~ "%_"
    refute Map.has_key?(read.metadata["filters"], "q")
  end

  test "structured filters and search reject malformed values before querying" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    for filters <- [
          %{q: String.duplicate("x", 201)},
          %{q: ["unexpected"]},
          %{actor_user_id: "not-a-uuid"},
          %{action: %{bad: "shape"}},
          %{resource_type: String.duplicate("x", 201)},
          %{request_id: ["unexpected"]}
        ] do
      assert {:error, :invalid_search_query} = Administration.list_audit_events(filters, subject)
    end

    assert 0 == Audit.count(%{tenant_id: account.tenant.id, action: "audit.read"})
  end

  test "audit read evidence records bounded normalized filters rather than whitespace padding" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    insert_event!(account, %{})
    padding = String.duplicate(" ", 10_000)

    assert {:ok, page} =
             Administration.list_audit_events(
               %{
                 "action" => padding <> "search-test" <> padding,
                 "resource_type" => padding <> "message" <> padding,
                 "request_id" => padding <> "search-request" <> padding,
                 "actor_user_id" => "",
                 "q" => padding <> "search" <> padding
               },
               subject
             )

    assert [_event] = page.events
    assert [read] = Audit.list(%{tenant_id: account.tenant.id, action: "audit.read"})

    assert read.metadata["filters"] == %{
             "action" => "search-test",
             "resource_type" => "message",
             "request_id" => "search-request"
           }

    assert read.metadata["query_present"]
    refute Jason.encode!(read.metadata) =~ padding
    refute Map.has_key?(read.metadata["filters"], "q")
  end

  test "a page cursor cannot expand the applied before timestamp" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    cutoff = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    older = insert_event!(account, %{inserted_at: DateTime.add(cutoff, -60, :second)})
    insert_event!(account, %{inserted_at: DateTime.add(cutoff, 60, :second)})

    cursor =
      %{inserted_at: DateTime.add(cutoff, 120, :second), id: Ecto.UUID.generate()}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, page} =
             Administration.list_audit_events(
               %{action: "search-test", before: DateTime.to_iso8601(cutoff), cursor: cursor},
               subject
             )

    assert [event] = page.events
    assert event.id == older.id
    assert is_nil(page.next_cursor)
  end

  test "equal timestamp boundaries compare canonical UUIDs across mixed-case cursors" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    lower_id = "80000000-0000-4000-8000-000000000000"

    for id <- [lower_id, "c0000000-0000-4000-8000-000000000000"] do
      insert_event!(account, %{id: id, inserted_at: timestamp})
    end

    cursor = fn id ->
      %{inserted_at: DateTime.to_iso8601(timestamp), id: id}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
    end

    earlier = cursor.("a0000000-0000-4000-8000-000000000000")
    later = cursor.("F0000000-0000-4000-8000-000000000000")

    for {continuation, before} <- [{earlier, later}, {later, earlier}] do
      assert {:ok, page} =
               Administration.list_audit_events(
                 %{action: "search-test", cursor: continuation, before: before},
                 subject
               )

      assert [event] = page.events
      assert event.id == lower_id
      assert is_nil(page.next_cursor)
    end
  end

  defp insert_event!(account, overrides) do
    %{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      actor_user_id: account.user.id,
      action: "search-test",
      resource_type: "message",
      resource_id: Ecto.UUID.generate(),
      metadata: %{},
      request_id: "search-request",
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
    |> Map.merge(overrides)
    |> TestSupport.insert!()
  end
end
