defmodule CommsCore.Telephony.ContactCenter do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Administration, Audit, Repo}
  alias CommsCore.Accounts.AccessGrant
  alias CommsCore.Telephony.{AgentState, Call, Route}

  @lock_budget_ms 15_000

  def agent_state(subject) do
    transaction(subject, false, fn grant, deadline ->
      require_member!(grant)

      result =
        agent_view(Repo.get_by(AgentState, tenant_id: grant.tenant_id, user_id: grant.user_id))

      fresh!(subject, grant, deadline, false)
      result
    end)
  end

  def set_agent_state(attrs, subject) when is_map(attrs) do
    with true <-
           MapSet.new(Enum.map(Map.keys(attrs), &to_string/1)) ==
             MapSet.new(~w(state duration_seconds version)),
         {:ok, requested} <- requested_state(value(attrs, :state)),
         seconds when is_integer(seconds) and seconds in 60..3_600 <-
           value(attrs, :duration_seconds),
         version when is_integer(version) and version >= 0 <- value(attrs, :version),
         true <- requested != :wrap_up or seconds <= 1_800 do
      transaction(subject, false, fn grant, deadline ->
        require_member!(grant)

        current =
          Repo.one(
            from(s in AgentState,
              where: s.tenant_id == ^grant.tenant_id and s.user_id == ^grant.user_id,
              lock: "FOR UPDATE"
            )
          )

        if version != if(current, do: current.version, else: 0), do: Repo.rollback(:stale_version)
        timestamp = now()

        state =
          (current || %AgentState{})
          |> AgentState.changeset(%{
            tenant_id: grant.tenant_id,
            user_id: grant.user_id,
            state: requested,
            expires_at: DateTime.add(timestamp, seconds, :second),
            version: version + 1
          })
          |> Repo.insert_or_update!()

        case Audit.record(%{
               tenant_id: grant.tenant_id,
               actor_user_id: grant.user_id,
               action: "telephony.agent_state.updated",
               resource_type: "telephony_agent_state",
               resource_id: state.id,
               metadata: %{state: requested, version: state.version}
             }) do
          {:ok, _} -> :ok
          _ -> Repo.rollback(:audit_failed)
        end

        fresh!(subject, grant, deadline, false)
        agent_view(state)
      end)
    else
      _ -> {:error, :invalid_agent_state}
    end
  end

  def set_agent_state(_, _), do: {:error, :invalid_agent_state}

  def queue_snapshot(subject) do
    transaction(subject, true, fn grant, deadline ->
      timestamp = now()
      routes = Repo.all(from(r in Route, where: r.tenant_id == ^grant.tenant_id, limit: 100))

      grouped =
        Repo.all(
          from(c in Call,
            where:
              c.tenant_id == ^grant.tenant_id and c.status in [:ringing, :answered] and
                not is_nil(c.route_id),
            group_by: [c.route_id, c.routing_status, c.status],
            select: {c.route_id, c.routing_status, c.status, count(c.id), min(c.started_at)}
          )
        )

      entries =
        Enum.map(routes, fn route ->
          facts = Enum.filter(grouped, fn {id, _, _, _, _} -> id == route.id end)
          waiting = Enum.filter(facts, fn {_, state, _, _, _} -> state == "waiting" end)
          oldest = waiting |> Enum.map(&elem(&1, 4)) |> Enum.min(DateTime, fn -> nil end)

          %{
            id: route.id,
            name: route.name,
            mode: route.mode,
            enabled: route.enabled,
            configured_members: length(route.member_ids),
            max_waiting: route.max_waiting,
            max_wait_seconds: route.max_wait_seconds,
            waiting_calls: count(facts, fn {_, routing, _, _, _} -> routing == "waiting" end),
            offered_calls:
              count(facts, fn {_, routing, status, _, _} ->
                routing == "offered" and status == :ringing
              end),
            answered_calls: count(facts, fn {_, _, status, _, _} -> status == :answered end),
            oldest_observed_wait_seconds:
              if(oldest, do: max(0, DateTime.diff(timestamp, oldest, :second)), else: nil)
          }
        end)

      fresh!(subject, grant, deadline, true)

      %{
        routes: entries,
        observed_at: timestamp,
        coverage: "current_retained_calls",
        online_presence_observed: false,
        historical_service_level_available: false,
        oldest_wait_basis: "call_started_at"
      }
    end)
  end

  # Existing Routing evaluates active membership and Identity DND independently.
  # Missing or expired explicit agent state preserves that existing eligibility.
  def ready?(tenant_id, user_id) do
    query = from(s in AgentState, where: s.tenant_id == ^tenant_id and s.user_id == ^user_id)
    query = if Repo.in_transaction?(), do: lock(query, "FOR SHARE"), else: query

    case Repo.one(query) do
      %AgentState{state: state, expires_at: expiry} ->
        DateTime.compare(expiry, now()) != :gt or state == :ready

      nil ->
        true
    end
  end

  @doc false
  def erase_user!(tenant_id, user_id) do
    if not Repo.in_transaction?(), do: raise("agent-state erasure requires the owner transaction")

    {count, _} =
      Repo.delete_all(
        from(s in AgentState, where: s.tenant_id == ^tenant_id and s.user_id == ^user_id)
      )

    {:ok, count}
  end

  def rollback_hazard_count, do: Repo.aggregate(AgentState, :count)

  defp transaction(subject, admin?, operation) do
    with {:ok, %AccessGrant{account_type: :human, access_scope: :workspace}} <-
           Accounts.access_grant(subject) do
      deadline = System.monotonic_time(:millisecond) + @lock_budget_ms

      Repo.transaction(
        fn ->
          case Accounts.lock_content_write_grant(subject, deadline) do
            {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} ->
              fresh!(subject, grant, deadline, admin?)
              operation.(grant, deadline)

            _ ->
              Repo.rollback(:forbidden)
          end
        end,
        timeout: 20_000
      )
    else
      _ -> {:error, :forbidden}
    end
  end

  defp fresh!(subject, original, deadline, admin?) do
    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)

    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant}
      when grant.tenant_id == original.tenant_id and grant.user_id == original.user_id ->
        if admin? and grant.role not in [:owner, :admin], do: Repo.rollback(:forbidden)
        if admin? and not grant.step_up_recent?, do: Repo.rollback(:step_up_required)

        case Administration.lock_call_policy(grant.tenant_id) do
          {:ok, _} -> :ok
          _ -> Repo.rollback(:forbidden)
        end

      _ ->
        Repo.rollback(:forbidden)
    end
  end

  defp require_member!(grant) do
    if is_nil(
         Repo.one(
           from(r in Route,
             where:
               r.tenant_id == ^grant.tenant_id and r.enabled and ^grant.user_id in r.member_ids,
             order_by: r.id,
             limit: 1,
             lock: "FOR SHARE",
             select: r.id
           )
         )
       ),
       do: Repo.rollback(:telephony_agent_not_assigned)
  end

  defp agent_view(nil),
    do: %{
      state: :ready,
      expires_at: nil,
      version: 0,
      explicit: false,
      online_presence_observed: false
    }

  defp agent_view(state) do
    active? = DateTime.compare(state.expires_at, now()) == :gt

    %{
      state: if(active?, do: state.state, else: :ready),
      expires_at: state.expires_at,
      version: state.version,
      explicit: active?,
      online_presence_observed: false
    }
  end

  defp requested_state(state) when state in [:ready, "ready"], do: {:ok, :ready}
  defp requested_state(state) when state in [:away, "away"], do: {:ok, :away}
  defp requested_state(state) when state in [:wrap_up, "wrap_up"], do: {:ok, :wrap_up}
  defp requested_state(_), do: {:error, :invalid_agent_state}

  defp count(facts, predicate),
    do: facts |> Enum.filter(predicate) |> Enum.map(&elem(&1, 3)) |> Enum.sum()

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
