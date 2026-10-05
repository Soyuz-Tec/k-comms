defmodule CommsCore.Telephony.Routing do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Administration, Audit, Outbox, Repo, RuntimePorts, ValidationError}
  alias CommsCore.Telephony.{Call, Number, ProviderControlPort, Route}
  alias CommsCore.Accounts.AccessGrant

  def list(subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, grant} <- access(subject) do
      {:ok,
       %{
         routes:
           Repo.all(from(r in Route, where: r.tenant_id == ^grant.tenant_id, limit: 100))
           |> Enum.map(&view/1),
         limit: 100
       }}
    end
  end

  def save(attrs, subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, initial} <- access(subject),
         reason when is_binary(reason) and byte_size(reason) in 3..500 <- value(attrs, :reason),
         ids when is_list(ids) and length(ids) in 1..25 <- value(attrs, :member_ids),
         true <-
           Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) and
             length(Enum.uniq(ids)) == length(ids) do
      Repo.transaction(fn ->
        with {:ok, _} <- Administration.lock_call_policy(initial.tenant_id),
             {:ok, users} <- Accounts.lock_active_human_directory_users(initial.tenant_id, ids),
             true <- length(users) == length(ids),
             {:ok, %AccessGrant{role: role, step_up_recent?: true} = grant} <-
               Accounts.lock_access_grant(subject),
             true <- role in [:owner, :admin] do
          number = Repo.get_by(Number, tenant_id: grant.tenant_id)
          if is_nil(number), do: Repo.rollback(:telephony_not_configured)

          existing =
            Repo.one(from(r in Route, where: r.number_id == ^number.id, lock: "FOR UPDATE")) ||
              %Route{}

          if existing.id && value(attrs, :version) != existing.version,
            do: Repo.rollback(:stale_version)

          mode = value(attrs, :mode)
          capability = if mode in [:queue, "queue"], do: :queues, else: :shared_lines

          if value(attrs, :enabled) == true and
               not (get_in(ProviderControlPort.capabilities(), [capability, :supported]) == true),
             do: Repo.rollback(:telephony_control_unsupported)

          parameters =
            Map.new(
              [:name, :mode, :policy, :max_waiting, :max_wait_seconds, :enabled],
              &{&1, value(attrs, &1)}
            )

          parameters =
            Map.merge(parameters, %{
              tenant_id: grant.tenant_id,
              number_id: number.id,
              member_ids: ids,
              version: (existing.version || 0) + 1
            })

          case existing |> Route.changeset(parameters) |> Repo.insert_or_update() do
            {:ok, saved} ->
              case Audit.record(%{
                     tenant_id: grant.tenant_id,
                     actor_user_id: grant.user_id,
                     action: "telephony.route.saved",
                     resource_type: "telephony_route",
                     resource_id: saved.id,
                     metadata: %{reason: reason, version: saved.version}
                   }) do
                {:ok, _} -> :ok
                _ -> Repo.rollback(:audit_failed)
              end

              view(saved)

            {:error, changeset} ->
              {:ok, error} = ValidationError.from(changeset)
              Repo.rollback(error)
          end
        else
          {:ok, %AccessGrant{step_up_recent?: false}} -> Repo.rollback(:step_up_required)
          _ -> Repo.rollback(:forbidden)
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_telephony_route}
    end
  end

  # Called only on the verified incoming-event transaction, under assignment lock.
  def admission(number) do
    route =
      Repo.one(
        from(r in Route,
          where: r.number_id == ^number.id and r.enabled == true,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(route) do
      %{
        user_id: number.user_id,
        route_id: nil,
        routing_status: "individual",
        offered_user_ids: [],
        route_expires_at: nil,
        eligible: available?(number.tenant_id, number.user_id)
      }
    else
      capability = if route.mode == :queue, do: :queues, else: :shared_lines

      waiting =
        Repo.aggregate(
          from(c in Call,
            where:
              c.route_id == ^route.id and c.routing_status == "waiting" and c.status == :ringing
          ),
          :count
        )

      supported = get_in(ProviderControlPort.capabilities(), [capability, :supported]) == true
      candidates = candidates(route)
      expiry = DateTime.add(DateTime.utc_now(), route.max_wait_seconds, :second)

      cond do
        not supported or waiting >= route.max_waiting ->
          %{
            user_id: number.user_id,
            route_id: route.id,
            routing_status: "unavailable",
            offered_user_ids: [],
            route_expires_at: expiry,
            eligible: false
          }

        candidates == [] and route.mode == :shared_line ->
          %{
            user_id: number.user_id,
            route_id: route.id,
            routing_status: "unavailable",
            offered_user_ids: [],
            route_expires_at: expiry,
            eligible: false
          }

        candidates == [] or (route.mode == :queue and waiting > 0) ->
          %{
            user_id: number.user_id,
            route_id: route.id,
            routing_status: "waiting",
            offered_user_ids: [],
            route_expires_at: expiry,
            eligible: true
          }

        true ->
          offered = if route.policy == :simultaneous, do: candidates, else: [hd(candidates)]

          route
          |> Route.changeset(%{cursor: rem(route.cursor + 1, length(route.member_ids))})
          |> Repo.update!()

          %{
            user_id: hd(offered),
            route_id: route.id,
            routing_status: "offered",
            offered_user_ids: offered,
            route_expires_at: expiry,
            eligible: true
          }
      end
    end
  end

  def visible_offer?(call, grant) do
    if is_nil(grant) do
      false
    else
      available =
        match?(
          {:ok, %{allowed: true}},
          Accounts.delivery_availability(call.tenant_id, grant.user_id, :call)
        )

      if is_nil(call.route_id) do
        available
      else
        route = Repo.get(Route, call.route_id)

        route && route.enabled && grant.user_id in route.member_ids &&
          grant.user_id in call.offered_user_ids && available
      end
    end
  end

  def effective_number(grant) do
    number = Repo.get_by(Number, tenant_id: grant.tenant_id)
    route = if number, do: Repo.get_by(Route, number_id: number.id, enabled: true), else: nil

    if number && (number.user_id == grant.user_id or (route && grant.user_id in route.member_ids)),
      do: number,
      else: nil
  end

  def eligible_recipient?(call, grant) do
    cond do
      is_nil(call.route_id) ->
        available?(call.tenant_id, grant.user_id)

      call.routing_status not in ["offered", "claimed"] ->
        false

      true ->
        route = Repo.get(Route, call.route_id)

        (route && route.enabled) and grant.user_id in route.member_ids and
          (call.routing_status == "claimed" or grant.user_id in call.offered_user_ids) and
          available?(call.tenant_id, grant.user_id)
    end
  end

  def enqueue_waiting(call) do
    if call.routing_status == "waiting" do
      %{"call_id" => call.id}
      |> Oban.Job.new(
        worker: RuntimePorts.job_worker_name!(:telephony_routing),
        queue: :lifecycle,
        max_attempts: 100
      )
      |> Oban.insert!()
    end

    :ok
  end

  def advance(id, caller) do
    if RuntimePorts.authorized_job_worker?(:telephony_routing, caller) do
      Repo.transaction(
        fn ->
          snapshot = Repo.get(Call, id)
          if is_nil(snapshot), do: Repo.rollback(:not_found)
          number = Repo.get!(Number, snapshot.number_id)
          {:ok, policy} = Administration.lock_call_policy(snapshot.tenant_id)

          route =
            Repo.one(from(r in Route, where: r.id == ^snapshot.route_id, lock: "FOR UPDATE"))

          if is_nil(route), do: Repo.rollback(:not_found)
          candidates = candidates(route)

          older_waiting =
            Repo.exists?(
              from(c in Call,
                where:
                  c.route_id == ^route.id and c.routing_status == "waiting" and
                    c.status == :ringing and
                    (c.started_at < ^snapshot.started_at or
                       (c.started_at == ^snapshot.started_at and c.id < ^snapshot.id))
              )
            )

          call = Repo.one(from(c in Call, where: c.id == ^id, lock: "FOR UPDATE"))

          ready_for_wait =
            policy.allow_audio_calls and call.status == :ringing and
              call.routing_status == "waiting" and
              DateTime.compare(call.route_expires_at, DateTime.utc_now()) == :gt and route.enabled and
              get_in(ProviderControlPort.capabilities(), [:queues, :supported]) == true

          if ready_for_wait do
            case ProviderControlPort.execute_control(queue_request(call)) do
              {:ok, _} -> :ok
              _ -> Repo.rollback(:telephony_provider_queue_unavailable)
            end
          end

          cond do
            call.status != :ringing or call.routing_status != "waiting" ->
              :complete

            DateTime.compare(call.route_expires_at, DateTime.utc_now()) != :gt ->
              :expired

            not policy.allow_audio_calls or not route.enabled or
                not (get_in(ProviderControlPort.capabilities(), [:queues, :supported]) == true) ->
              :unavailable

            candidates == [] or older_waiting ->
              {:wait, 5}

            true ->
              selected = hd(candidates)

              saved =
                call
                |> Call.changeset(%{
                  user_id: selected,
                  offered_user_ids: [selected],
                  routing_status: "offered"
                })
                |> Repo.update!()

              Outbox.insert_and_enqueue!(%{
                tenant_id: saved.tenant_id,
                event_type: "telephony.call.updated",
                aggregate_type: "telephony_call",
                aggregate_id: saved.id,
                payload: %{call_id: saved.id, user_id: selected, status: "ringing"},
                available_at: DateTime.utc_now()
              })

              route
              |> Route.changeset(%{cursor: rem(route.cursor + 1, length(route.member_ids))})
              |> Repo.update!()

              {:offered, number.phone_number}
          end
        end,
        timeout: 30_000
      )
    else
      {:error, :forbidden}
    end
  end

  def provider_request(id, caller) do
    if RuntimePorts.authorized_job_worker?(:telephony_routing, caller) do
      case Repo.get(Call, id) do
        %Call{status: :ringing, routing_status: "waiting"} = call ->
          {:ok, queue_request(call)}

        _ ->
          {:ok, nil}
      end
    else
      {:error, :forbidden}
    end
  end

  defp queue_request(call) do
    %CommsCore.Telephony.ControlRequest{
      command_id: call.id,
      call_id: call.id,
      tenant_id: call.tenant_id,
      action: :queue_waiting,
      provider_room: call.provider_room,
      provider_identity: call.provider_identity,
      destination: nil,
      pbx_state: %{},
      expires_at: call.route_expires_at,
      call_expires_at: call.expires_at,
      system: true,
      reconcile: true
    }
  end

  defp candidates(route) do
    ids = route.member_ids
    rotated = Enum.drop(ids, route.cursor) ++ Enum.take(ids, route.cursor)
    # Lock all members in canonical order before evaluating availability.
    active =
      case Accounts.lock_active_human_directory_users(route.tenant_id, Enum.sort(ids)) do
        {:ok, users} ->
          MapSet.new(Enum.map(users, & &1.id))

        _ ->
          Enum.reduce(Enum.sort(ids), MapSet.new(), fn id, active ->
            case Accounts.lock_active_human_directory_users(route.tenant_id, [id]) do
              {:ok, [_]} -> MapSet.put(active, id)
              _ -> active
            end
          end)
      end

    Enum.filter(rotated, fn id ->
      MapSet.member?(active, id) and available?(route.tenant_id, id) and
        not Repo.exists?(
          from(c in Call,
            where:
              c.tenant_id == ^route.tenant_id and c.user_id == ^id and
                c.status in [:ringing, :answered] and c.routing_status != "waiting"
          )
        )
    end)
  end

  defp available?(tenant_id, id) do
    with {:ok, [_]} <- Accounts.lock_active_human_directory_users(tenant_id, [id]),
         {:ok, %{allowed: true}} <- Accounts.delivery_availability(tenant_id, id, :call) do
      true
    else
      _ -> false
    end
  end

  defp access(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} -> {:ok, grant}
      _ -> {:error, :forbidden}
    end
  end

  defp view(route),
    do:
      Map.take(route, [
        :id,
        :name,
        :mode,
        :policy,
        :member_ids,
        :max_waiting,
        :max_wait_seconds,
        :enabled,
        :version
      ])

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
