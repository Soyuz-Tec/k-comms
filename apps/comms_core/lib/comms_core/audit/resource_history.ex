defmodule CommsCore.Audit.ResourceHistory do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Audit.{
    AuditEvent,
    Event,
    ResourceHistoryPage,
    ResourceHistoryQuery,
    ResourceHistorySnapshot
  }

  alias CommsCore.Repo
  @maximum_snapshot_events 5_000
  @ttl_seconds 3_600
  @maximum_live_snapshots_per_tenant 100

  def page(%ResourceHistoryQuery{} = input) do
    if Repo.in_transaction?() do
      do_page(input)
    else
      case Repo.transaction(fn -> do_page(input) end, timeout: 20_000) do
        {:ok, result} -> result
        {:error, _} -> {:error, :audit_history_snapshot_unavailable}
      end
    end
  end

  def page(_), do: {:error, :invalid_audit_history_query}

  defp do_page(input) do
    deadline =
      min(
        input.deadline || System.monotonic_time(:millisecond) + 15_000,
        System.monotonic_time(:millisecond) + 15_000
      )

    with :ok <- validate(input), {:ok, snapshot} <- snapshot(input, deadline) do
      query = scoped_query(input) |> where([event], event.id in ^snapshot.event_ids)

      rows =
        budgeted(deadline, fn ->
          query
          |> after_boundary(input.after)
          |> order_by([event], asc: event.inserted_at, asc: event.id)
          |> limit(^(input.limit + 1))
          |> Repo.all()
        end)

      earliest_at =
        budgeted(deadline, fn ->
          query
          |> order_by([event], asc: event.inserted_at, asc: event.id)
          |> limit(1)
          |> select([event], event.inserted_at)
          |> Repo.one()
        end)

      through =
        budgeted(deadline, fn ->
          query
          |> order_by([event], desc: event.inserted_at, desc: event.id)
          |> limit(1)
          |> select([event], {event.inserted_at, event.id})
          |> Repo.one()
        end)

      page =
        %ResourceHistoryPage{
          events: rows |> Enum.take(input.limit) |> Enum.map(&Event.from_schema/1),
          has_more: length(rows) > input.limit,
          through: through,
          origin_present:
            budgeted(deadline, fn ->
              Repo.exists?(where(query, [event], event.action == ^input.origin_action))
            end),
          earliest_at: earliest_at,
          snapshot_id: snapshot.id,
          observed_at: snapshot.observed_at,
          expires_at: snapshot.expires_at,
          captured_count: length(snapshot.event_ids),
          retained_count: budgeted(deadline, fn -> Repo.aggregate(query, :count) end),
          snapshot_truncated: snapshot.truncated
        }

      if DateTime.compare(snapshot.expires_at, DateTime.utc_now()) == :gt,
        do: {:ok, page},
        else: {:error, :audit_history_snapshot_unavailable}
    end
  end

  def rollback_hazard_count, do: Repo.aggregate(ResourceHistorySnapshot, :count)

  def purge_expired(%DateTime{} = timestamp, limit)
      when is_integer(limit) and limit in 1..1_000 do
    ids =
      ResourceHistorySnapshot
      |> where([snapshot], snapshot.expires_at <= ^timestamp)
      |> order_by([snapshot], asc: snapshot.expires_at, asc: snapshot.id)
      |> limit(^(limit + 1))
      |> select([snapshot], snapshot.id)
      |> Repo.all()

    {count, _} =
      Repo.delete_all(
        from(snapshot in ResourceHistorySnapshot,
          where: snapshot.id in ^Enum.take(ids, limit)
        )
      )

    %{deleted_count: count, has_more: length(ids) > limit}
  end

  defp snapshot(%{snapshot_id: nil} = input, deadline) do
    budgeted(deadline, fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "audit-history:" <> input.tenant_id
      ])
    end)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    # Bounded owner maintenance stores no actor/content/provider metadata.
    expired =
      budgeted(deadline, fn ->
        ResourceHistorySnapshot
        |> where(
          [snapshot],
          snapshot.tenant_id == ^input.tenant_id and
            snapshot.expires_at <= ^timestamp
        )
        |> order_by([snapshot], asc: snapshot.expires_at)
        |> limit(100)
        |> select([snapshot], snapshot.id)
        |> Repo.all()
      end)

    budgeted(deadline, fn ->
      Repo.delete_all(from(snapshot in ResourceHistorySnapshot, where: snapshot.id in ^expired))
    end)

    if budgeted(deadline, fn ->
         Repo.aggregate(
           from(snapshot in ResourceHistorySnapshot,
             where: snapshot.tenant_id == ^input.tenant_id and snapshot.expires_at > ^timestamp
           ),
           :count
         )
       end) >=
         @maximum_live_snapshots_per_tenant do
      {:error, :audit_history_snapshot_capacity}
    else
      # One SELECT fixes membership even if a later append uses an equal/backdated
      # event timestamp. Never reconstruct membership from a timestamp high-water.
      ids =
        budgeted(deadline, fn ->
          scoped_query(input)
          |> order_by([event], asc: event.inserted_at, asc: event.id)
          |> limit(^(@maximum_snapshot_events + 1))
          |> select([event], event.id)
          |> Repo.all()
        end)

      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      snapshot = %ResourceHistorySnapshot{
        tenant_id: input.tenant_id,
        resource_type: input.resource_type,
        resource_id: input.resource_id,
        actions: Enum.sort(Enum.uniq(input.actions)),
        origin_action: input.origin_action,
        event_ids: Enum.take(ids, @maximum_snapshot_events),
        truncated: length(ids) > @maximum_snapshot_events,
        observed_at: observed_at,
        expires_at: DateTime.add(observed_at, @ttl_seconds, :second)
      }

      {:ok, budgeted(deadline, fn -> Repo.insert!(snapshot) end)}
    end
  end

  defp snapshot(input, deadline) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    actions = Enum.sort(Enum.uniq(input.actions))

    case budgeted(deadline, fn ->
           Repo.one(
             from(snapshot in ResourceHistorySnapshot,
               where:
                 snapshot.id == ^input.snapshot_id and snapshot.tenant_id == ^input.tenant_id and
                   snapshot.resource_type == ^input.resource_type and
                   snapshot.resource_id == ^input.resource_id and
                   snapshot.actions == ^actions and snapshot.origin_action == ^input.origin_action and
                   snapshot.expires_at > ^timestamp,
               lock: "FOR SHARE"
             )
           )
         end) do
      nil -> {:error, :audit_history_snapshot_unavailable}
      snapshot -> {:ok, snapshot}
    end
  end

  defp scoped_query(input),
    do:
      from(event in AuditEvent,
        where:
          event.tenant_id == ^input.tenant_id and event.resource_type == ^input.resource_type and
            event.resource_id == ^input.resource_id and event.action in ^input.actions
      )

  defp after_boundary(query, nil), do: query

  defp after_boundary(query, {timestamp, id}),
    do:
      where(
        query,
        [event],
        event.inserted_at > ^timestamp or (event.inserted_at == ^timestamp and event.id > ^id)
      )

  defp validate(input) do
    if uuid?(input.tenant_id) and uuid?(input.resource_id) and string?(input.resource_type, 64) and
         is_list(input.actions) and length(input.actions) in 1..16 and
         Enum.all?(input.actions, &string?(&1, 100)) and string?(input.origin_action, 100) and
         input.origin_action in input.actions and is_integer(input.limit) and
         input.limit in 1..5_000 and
         boundary?(input.after) and (is_nil(input.snapshot_id) or uuid?(input.snapshot_id)) and
         (is_nil(input.after) or not is_nil(input.snapshot_id)) and
         (is_nil(input.deadline) or is_integer(input.deadline)),
       do: :ok,
       else: {:error, :invalid_audit_history_query}
  end

  defp budgeted(deadline, operation) do
    budget!(deadline)
    result = operation.()
    budget!(deadline)
    result
  end

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:audit_history_snapshot_unavailable)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline,
      do: Repo.rollback(:audit_history_snapshot_unavailable)

    :ok
  end

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp string?(value, maximum), do: is_binary(value) and byte_size(value) in 1..maximum
  defp boundary?(nil), do: true
  defp boundary?({%DateTime{}, id}), do: uuid?(id)
  defp boundary?(_), do: false
end
