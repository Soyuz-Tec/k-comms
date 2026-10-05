defmodule CommsCore.Audit.ResourceHistoryTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.Audit
  alias CommsCore.Audit.{AuditEvent, ResourceHistoryQuery, ResourceHistorySnapshot, TestSupport}
  alias CommsTestSupport.Fixtures

  setup do
    account = Fixtures.account_fixture()

    query = %ResourceHistoryQuery{
      tenant_id: account.tenant.id,
      resource_type: "deletion_request",
      resource_id: Ecto.UUID.generate(),
      actions: ["deletion_request.create", "deletion_request.claim"],
      origin_action: "deletion_request.create",
      limit: 2
    }

    %{account: account, query: query}
  end

  test "keyset pages equal timestamps in exact UUID order, with exact resource/action scope",
       ctx do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    ids = Enum.map(1..5, &uuid/1)
    for id <- Enum.reverse(ids), do: event(ctx.query, id: id, inserted_at: timestamp)
    event(ctx.query, resource_id: Ecto.UUID.generate())
    event(ctx.query, resource_type: "other")
    event(ctx.query, action: "deletion_request.history_export")
    foreign = Fixtures.account_fixture()
    event(ctx.query, tenant_id: foreign.tenant.id)
    assert {:ok, first} = Audit.resource_history_page(ctx.query)
    assert Enum.map(first.events, & &1.id) == Enum.take(ids, 2)
    assert first.has_more and first.origin_present
    assert first.captured_count == 5

    assert {:ok, second} =
             Audit.resource_history_page(%{
               ctx.query
               | snapshot_id: first.snapshot_id,
                 after: {timestamp, List.last(first.events).id}
             })

    assert Enum.map(second.events, & &1.id) == Enum.slice(ids, 2, 2)

    assert {:ok, third} =
             Audit.resource_history_page(%{
               ctx.query
               | snapshot_id: first.snapshot_id,
                 after: {timestamp, List.last(second.events).id}
             })

    assert Enum.map(third.events, & &1.id) == [List.last(ids)]
    refute third.has_more
  end

  test "snapshot membership excludes later equal-timestamp and backdated inserts", ctx do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    event(ctx.query, id: uuid(10), inserted_at: timestamp)
    event(ctx.query, id: uuid(30), inserted_at: timestamp)
    assert {:ok, first} = Audit.resource_history_page(%{ctx.query | limit: 1})
    event(ctx.query, id: uuid(20), inserted_at: timestamp)
    event(ctx.query, inserted_at: DateTime.add(timestamp, -60, :second))

    assert {:ok, old} =
             Audit.resource_history_page(%{
               ctx.query
               | snapshot_id: first.snapshot_id,
                 after: {timestamp, uuid(10)},
                 limit: 50
             })

    assert Enum.map(old.events, & &1.id) == [uuid(30)]
    assert old.captured_count == 2
    assert {:ok, fresh} = Audit.resource_history_page(%{ctx.query | limit: 50})
    assert length(fresh.events) == 4
  end

  test "empty snapshots remain empty when real history later appears", ctx do
    assert {:ok, empty} = Audit.resource_history_page(ctx.query)
    event(ctx.query)

    assert {:ok, retained} =
             Audit.resource_history_page(%{ctx.query | snapshot_id: empty.snapshot_id})

    assert retained.events == [] and retained.captured_count == 0
    refute retained.origin_present
    assert retained.earliest_at == nil
  end

  test "retention may remove fixed members without admitting replacement events", ctx do
    original = event(ctx.query)
    assert {:ok, snapshot} = Audit.resource_history_page(ctx.query)
    Repo.delete!(Repo.get!(AuditEvent, original.id))
    event(ctx.query)

    assert {:ok, retained} =
             Audit.resource_history_page(%{ctx.query | snapshot_id: snapshot.snapshot_id})

    assert retained.events == []
    assert retained.captured_count == 1 and retained.retained_count == 0
    refute retained.origin_present
  end

  test "snapshot is bound to tenant/resource/type/actions, not a generic audit capability", ctx do
    event(ctx.query)
    assert {:ok, snapshot} = Audit.resource_history_page(ctx.query)
    foreign = Fixtures.account_fixture()

    for changed <- [
          %{ctx.query | tenant_id: foreign.tenant.id},
          %{ctx.query | resource_id: Ecto.UUID.generate()},
          %{ctx.query | resource_type: "tenant"},
          %{ctx.query | actions: ["deletion_request.create"]}
        ] do
      assert {:error, :audit_history_snapshot_unavailable} =
               Audit.resource_history_page(%{changed | snapshot_id: snapshot.snapshot_id})
    end

    assert {:error, :invalid_audit_history_query} =
             Audit.resource_history_page(%{ctx.query | limit: 5_001})

    assert {:error, :invalid_audit_history_query} =
             Audit.resource_history_page(%{
               ctx.query
               | after: {DateTime.utc_now(), Ecto.UUID.generate()}
             })
  end

  test "snapshot expiry refuses reads and bounded owner housekeeping deletes only expired rows",
       ctx do
    assert {:ok, first} = Audit.resource_history_page(ctx.query)
    assert {:ok, second} = Audit.resource_history_page(ctx.query)
    past = DateTime.add(DateTime.utc_now(), -7_200, :second)

    Repo.get!(ResourceHistorySnapshot, first.snapshot_id)
    |> Ecto.Changeset.change(observed_at: past, expires_at: DateTime.add(past, 3_600, :second))
    |> Repo.update!()

    assert {:error, :audit_history_snapshot_unavailable} =
             Audit.resource_history_page(%{ctx.query | snapshot_id: first.snapshot_id})

    assert %{deleted_count: 1, has_more: false} =
             Audit.purge_resource_history_snapshots(DateTime.utc_now(), 1)

    assert Repo.get(ResourceHistorySnapshot, first.snapshot_id) == nil
    assert Repo.get(ResourceHistorySnapshot, second.snapshot_id)
  end

  test "capture is bounded at 5000 and discloses the omitted source tail", ctx do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..5_001, fn n ->
        %{
          id: uuid(10_000 + n),
          tenant_id: ctx.query.tenant_id,
          action: "deletion_request.create",
          resource_type: ctx.query.resource_type,
          resource_id: ctx.query.resource_id,
          metadata: %{},
          inserted_at: timestamp
        }
      end)

    Repo.insert_all(AuditEvent, rows)
    assert {:ok, snapshot} = Audit.resource_history_page(%{ctx.query | limit: 5_000})
    assert snapshot.snapshot_truncated and snapshot.captured_count == 5_000
    assert snapshot.retained_count == 5_000 and length(snapshot.events) == 5_000
    refute snapshot.has_more
  end

  test "tenant admission caps100 live snapshots and retained metadata blocks old rollback", ctx do
    pages =
      for _ <- 1..100 do
        assert {:ok, page} = Audit.resource_history_page(ctx.query)
        page
      end

    assert {:error, :audit_history_snapshot_capacity} = Audit.resource_history_page(ctx.query)
    assert Audit.rollback_history_snapshot_hazard_count() == 100

    assert {:ok, _existing} =
             Audit.resource_history_page(%{ctx.query | snapshot_id: hd(pages).snapshot_id})

    expired = DateTime.add(DateTime.utc_now(), -7_200, :second)

    Repo.get!(ResourceHistorySnapshot, hd(pages).snapshot_id)
    |> Ecto.Changeset.change(
      observed_at: expired,
      expires_at: DateTime.add(expired, 3_600, :second)
    )
    |> Repo.update!()

    assert Audit.rollback_history_snapshot_hazard_count() == 100
    assert %{deleted_count: 1} = Audit.purge_resource_history_snapshots(DateTime.utc_now(), 1)
    assert Audit.rollback_history_snapshot_hazard_count() == 99
    assert {:ok, _new} = Audit.resource_history_page(ctx.query)
  end

  defp event(query, overrides \\ []) do
    TestSupport.insert!(
      Map.merge(
        %{
          tenant_id: query.tenant_id,
          action: "deletion_request.create",
          resource_type: query.resource_type,
          resource_id: query.resource_id,
          metadata: %{}
        },
        Map.new(overrides)
      )
    )
  end

  defp uuid(integer),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(integer), 12, "0")
end
