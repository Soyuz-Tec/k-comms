defmodule CommsCore.Telephony.Lifecycle do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Administration, Audit, Outbox, Repo, RuntimePorts, ValidationError}
  alias CommsCore.Accounts.AccessGrant

  alias CommsCore.Telephony.{
    Call,
    CallView,
    CallMonitor,
    CredentialRequest,
    Number,
    Mailboxes,
    ProviderCommand,
    ProviderControlPort,
    ControlCommand,
    ProviderEvent,
    ProviderWebhookPort,
    RoomTombstone,
    Routing
  }

  @active [:ringing, :answered]
  @dispatch_lease_seconds 120
  @cleanup_horizon_seconds 120
  @event_types [
    "participant_joined",
    "participant_left",
    "participant_connection_aborted",
    "room_finished",
    "answered",
    "provider_failed"
  ]

  def config(subject) do
    with {:ok, grant} <- access(subject) do
      {:ok, config_view(grant, false)}
    end
  end

  def admin_config(subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, grant} <- access(subject) do
      {:ok, config_view(grant, true)}
    end
  end

  def provision(attrs, subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         :ok <- reason(attrs),
         {:ok, _grant} <- access(subject) do
      transaction(fn ->
        grant = lock_access!(subject, [value(attrs, :user_id)])
        if grant.role not in [:owner, :admin], do: Repo.rollback(:forbidden)
        if not grant.step_up_recent?, do: Repo.rollback(:step_up_required)
        lock_tenant!(grant.tenant_id)
        user_id = value(attrs, :user_id)
        require_human!(grant.tenant_id, user_id)
        lock_key!("assignment:" <> grant.tenant_id)

        if Repo.exists?(
             from(c in Call, where: c.tenant_id == ^grant.tenant_id and c.status in ^@active)
           ),
           do: Repo.rollback(:active_call_conflict)

        number = Repo.get_by(Number, tenant_id: grant.tenant_id) || %Number{}

        parameters =
          Map.new(
            [:user_id, :phone_number, :extension, :inbound_trunk_id, :outbound_trunk_id],
            &{&1, value(attrs, &1)}
          )

        parameters = Map.put(parameters, :tenant_id, grant.tenant_id)

        case number |> Number.changeset(parameters) |> Repo.insert_or_update() do
          {:ok, saved} ->
            audit!(saved.tenant_id, grant.user_id, "telephony.provisioned", saved.id, %{
              reason: value(attrs, :reason)
            })

            config_view(grant, true)

          {:error, changeset} ->
            rollback_validation!(changeset)
        end
      end)
    end
  end

  def list_calls(subject, params) do
    with {:ok, grant} <- access(subject),
         {:ok, cursor} <- parse_cursor(value(params, :cursor)),
         {:ok, scope} <- parse_scope(value(params, :scope)) do
      limit = parse_limit(value(params, :limit))

      query =
        from(c in Call,
          where:
            c.tenant_id == ^grant.tenant_id and c.routing_status not in ["waiting", "voicemail"] and
              (c.user_id == ^grant.user_id or
                 (c.status == :ringing and c.routing_status == "offered" and
                    ^grant.user_id in c.offered_user_ids))
        )

      query = if scope == :active, do: where(query, [c], c.status in ^@active), else: query

      query =
        if scope == :missed,
          do: where(query, [c], c.direction == :inbound and c.status in [:no_answer, :busy]),
          else: query

      query =
        case cursor do
          nil ->
            query

          {time, id} ->
            where(query, [c], c.started_at < ^time or (c.started_at == ^time and c.id < ^id))
        end

      rows =
        Repo.all(
          from(c in query, order_by: [desc: c.started_at, desc: c.id], limit: ^(limit + 1))
        )

      {page, more} = Enum.split(rows, limit)

      {:ok,
       %{
         calls: Enum.map(page, &view(&1, grant)),
         limit: limit,
         has_more: more != [],
         next_cursor: if(more == [], do: nil, else: cursor_for(List.last(page)))
       }}
    end
  end

  def get_call(id, subject) do
    with {:ok, grant} <- access(subject),
         {:ok, id} <- uuid(id),
         %Call{} = call <-
           Repo.one(
             from(c in Call,
               where:
                 c.id == ^id and c.tenant_id == ^grant.tenant_id and
                   c.routing_status not in ["waiting", "voicemail"] and
                   (c.user_id == ^grant.user_id or
                      (c.status == :ringing and c.routing_status == "offered" and
                         ^grant.user_id in c.offered_user_ids))
             )
           ) do
      {:ok, view(call, grant)}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def start_outbound(attrs, subject) do
    with {:ok, _grant} <- access(subject),
         {:ok, destination} <- phone(value(attrs, :destination)),
         {:ok, key} <- idempotency_key(value(attrs, :idempotency_key)) do
      transaction(fn ->
        grant = lock_access!(subject)
        lock_tenant!(grant.tenant_id)
        require_human!(grant.tenant_id, grant.user_id)
        lock_key!("assignment:" <> grant.tenant_id)
        lock_key!("user:" <> grant.tenant_id <> ":" <> grant.user_id)
        number = assigned_number!(grant)

        replay =
          Repo.get_by(Call,
            tenant_id: grant.tenant_id,
            user_id: grant.user_id,
            idempotency_key: key
          )

        if replay do
          if replay.to_number != destination, do: Repo.rollback(:idempotency_conflict)
          {view(replay, grant), :replayed}
        else
          if active_user_call?(grant.tenant_id, grant.user_id), do: Repo.rollback(:busy)
          timestamp = now()
          id = Ecto.UUID.generate()

          call =
            insert_call!(number, %{
              id: id,
              user_id: grant.user_id,
              direction: :outbound,
              from_number: number.phone_number,
              to_number: destination,
              provider_room: "kc_tel_" <> String.replace(id, "-", ""),
              provider_identity: "kc_tel_sip_" <> String.replace(id, "-", ""),
              idempotency_key: key,
              answer_session_id: grant.session_id,
              answer_device_id: grant.device_id,
              app_identity: app_identity(id, grant.device_id),
              started_at: timestamp,
              expires_at:
                earliest_expiry(
                  DateTime.add(timestamp, ring_seconds(), :second),
                  grant.effective_expires_at
                )
            })

          enqueue!(:telephony_dispatch, call.id)
          enqueue!(:telephony_expiry, call.id, call.expires_at)
          publish!(call)
          {view(call, grant), :created}
        end
      end)
      |> unwrap_created()
    end
  end

  def answer(id, subject, issuer), do: credential(id, subject, issuer, :answer)
  def join(id, subject, issuer), do: credential(id, subject, issuer, :join)

  @doc false
  def native_wake_recipients(tenant, id) do
    case Repo.one(
           from(c in Call,
             where:
               c.id == ^id and c.tenant_id == ^tenant and c.status == :ringing and
                 c.direction == :inbound and is_nil(c.answer_session_id) and c.expires_at > ^now()
           )
         ) do
      nil ->
        {:ok, []}

      call ->
        {:ok,
         if(call.routing_status == "offered", do: call.offered_user_ids, else: [call.user_id])}
    end
  end

  @doc false
  def native_wake_authority(id, subject) do
    if Repo.in_transaction?() do
      grant = lock_access!(subject)
      lock_tenant!(grant.tenant_id)
      call = own_call!(id, grant)

      if not view(call, grant).can_answer || not Routing.eligible_recipient?(call, grant),
        do: Repo.rollback(:native_push_unavailable)

      {:ok, earliest_expiry(call.expires_at, grant.effective_expires_at)}
    else
      {:error, :transaction_required}
    end
  end

  defp credential(id, subject, issuer, operation) when is_function(issuer, 1) do
    with {:ok, _grant} <- access(subject), {:ok, id} <- uuid(id) do
      transaction(fn ->
        grant = lock_access!(subject)
        lock_tenant!(grant.tenant_id)
        require_human!(grant.tenant_id, grant.user_id)
        call = own_call!(id, grant)

        if call.status not in @active or due?(call),
          do: Repo.rollback(:call_ended)

        if call.control_state in ["transferred", "voicemail"] or
             provider_handoff?(call) or provider_capture?(call),
           do: Repo.rollback(:invalid_call_action)

        if operation == :answer and (call.direction != :inbound or call.status != :ringing),
          do: Repo.rollback(:invalid_call_action)

        if operation == :join and call.direction == :inbound and is_nil(call.answer_session_id),
          do: Repo.rollback(:answer_required)

        if call.answer_session_id &&
             (call.answer_session_id != grant.session_id or
                call.answer_device_id != grant.device_id),
           do: Repo.rollback(:answered_elsewhere)

        if call.direction == :inbound and is_nil(call.answer_session_id) do
          if not Routing.eligible_recipient?(call, grant),
            do: Repo.rollback(:recipient_unavailable)

          if call.user_id != grant.user_id and active_user_call?(grant.tenant_id, grant.user_id),
            do: Repo.rollback(:busy)
        end

        identity = call.app_identity || app_identity(call.id, grant.device_id)

        call =
          update!(call, %{
            user_id: grant.user_id,
            routing_status: if(call.route_id, do: "claimed", else: call.routing_status),
            offered_user_ids: [],
            answer_session_id: grant.session_id,
            answer_device_id: grant.device_id,
            app_identity: identity,
            expires_at: earliest_expiry(call.expires_at, grant.effective_expires_at)
          })

        request = %CredentialRequest{
          call_id: call.id,
          provider_room: call.provider_room,
          provider_identity: identity,
          user_id: grant.user_id,
          device_id: grant.device_id,
          session_id: grant.session_id,
          authorization_expires_at:
            earliest_expiry(
              call.expires_at,
              grant.effective_expires_at
            )
        }

        case issuer.(request) do
          {:ok, issued} -> {view(call, grant), issued}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_credential()
    end
  end

  def reject(id, subject), do: terminate(id, subject, :declined)
  def end_call(id, subject), do: terminate(id, subject, :ended)

  defp terminate(id, subject, desired) do
    with {:ok, _grant} <- access(subject), {:ok, id} <- uuid(id) do
      transaction(fn ->
        grant = lock_access!(subject)
        call = own_call!(id, grant)

        cond do
          call.status not in @active ->
            view(call, grant)

          desired == :declined and
              (call.direction != :inbound or call.status != :ringing or
                 not is_nil(call.answer_session_id)) ->
            Repo.rollback(:invalid_call_action)

          (desired == :ended and call.answer_session_id) &&
              call.answer_session_id != grant.session_id ->
            Repo.rollback(:answered_elsewhere)

          true ->
            status =
              if desired == :ended and is_nil(call.answered_at), do: :cancelled, else: desired

            view(finish!(call, status, "user_" <> Atom.to_string(status)), grant)
        end
      end)
    end
  end

  def callback(event, caller) do
    if not ProviderWebhookPort.authorized_adapter?(caller) do
      {:error, :forbidden}
    else
      with {:ok, event} <- validate_event(event) do
        transaction(fn ->
          lock_key!("event:" <> event.event_id)

          case Repo.get_by(ProviderEvent, event_id: event.event_id) do
            %ProviderEvent{call_id: id} ->
              call = lock_call!(id)
              if call.provider_room != event.room, do: Repo.rollback(:event_conflict)
              {view(call, nil), :duplicate}

            nil ->
              lock_key!("room:" <> event.room)
              snapshot = Repo.get_by(Call, provider_room: event.room)

              if is_nil(snapshot) and event.event_type == "room_finished" and
                   String.starts_with?(event.room, "kc_tel_inbound_") do
                tombstone_room!(event.room)
                {nil, :ignored}
              else
                authorized? = is_nil(snapshot) or authorized_call?(snapshot)
                call = if snapshot, do: lock_call!(snapshot.id), else: inbound!(event)
                if is_nil(call), do: Repo.rollback(:unrelated_provider_event)
                if not event_matches?(call, event), do: Repo.rollback(:invalid_provider_event)
                record_event!(call, event)

                if call.status not in @active do
                  if event.event_type == "participant_joined", do: request_cleanup!(call)
                  {view(call, nil), :ignored}
                else
                  if due?(call) do
                    {view(expire_call!(call), nil), :applied}
                  else
                    if authorized? do
                      updated = apply_event!(call, event)
                      {view(updated, nil), :applied}
                    else
                      {view(finish!(call, :failed, "access_revoked"), nil), :applied}
                    end
                  end
                end
              end
          end
        end)
        |> unwrap_event()
        |> case do
          {:error, :unrelated_provider_event} -> {:ok, nil, :ignored}
          result -> result
        end
      end
    end
  end

  def claim_dispatch(id, caller) do
    worker_transaction(:telephony_dispatch, caller, id, fn call ->
      cond do
        call.status not in @active ->
          :already_terminal

        due?(call) ->
          expire_call!(call)
          :already_terminal

        call.dispatch_status == :started ->
          :already_dispatched

        is_nil(call.app_connected_at) ->
          {:not_ready, 2}

        call.dispatch_status == :dispatching ->
          %{command(call) | reconcile: true}

        lease_active?(call.dispatch_claimed_at, @dispatch_lease_seconds) ->
          {:not_ready, 5}

        true ->
          reconcile = call.direction == :inbound
          call = update!(call, %{dispatch_status: :dispatching, dispatch_claimed_at: now()})
          %{command(call) | reconcile: reconcile}
      end
    end)
  end

  def complete_dispatch(id, result, caller) do
    worker_transaction(:telephony_dispatch, caller, id, fn call ->
      cond do
        call.status not in @active ->
          call = correlate_late_answer!(call, result)
          request_cleanup!(call)
          :already_terminal

        due?(call) ->
          call = correlate_late_answer!(call, result)
          expire_call!(call)
          request_cleanup!(call)
          :already_terminal

        true ->
          case result do
            :pending ->
              if call.direction == :inbound, do: update!(call, %{dispatch_claimed_at: nil})
              :pending

            {:ok, details} ->
              if valid_answer_result?(call, details) do
                call =
                  update!(call, %{
                    provider_call_id: value(details, :provider_call_id),
                    dispatch_status: :started
                  })

                answer_connected!(call)
                :answered
              else
                finish!(call, :failed, "provider_invalid_outcome")
                :failed
              end

            {:error, reason} ->
              {status, end_reason} =
                if reason == :no_answer do
                  unanswered_outcome(call, "provider_no_answer")
                else
                  {if(reason in [:busy, :declined], do: reason, else: :failed),
                   "provider_" <> safe_reason(reason)}
                end

              finish!(call, status, end_reason)
              :failed

            _ ->
              finish!(call, :failed, "provider_invalid_outcome")
              :failed
          end
      end
    end)
  end

  def expire(id, caller) do
    worker_transaction(
      :telephony_expiry,
      caller,
      id,
      fn call ->
        cond do
          call.status not in @active ->
            :already_terminal

          provider_capture?(call) and Mailboxes.capture_lifecycle(call) in [:complete, :absent] ->
            finish!(call, :ended, "voicemail_capture_complete")
            :expired

          not due?(call) and (provider_handoff?(call) or provider_capture?(call)) ->
            request =
              if provider_capture?(call),
                do: %{command(call) | control_state: "voicemail"},
                else: command(call)

            case ProviderControlPort.bound_call_status(request) do
              {:ok, :ended} ->
                finish!(
                  call,
                  :ended,
                  if(provider_capture?(call),
                    do: "voicemail_remote_end",
                    else: "transferred_remote_end"
                  )
                )

                :expired

              _ ->
                {:not_due, min(max(DateTime.diff(call.expires_at, now(), :second), 1), 5)}
            end

          not due?(call) ->
            {:not_due, max(DateTime.diff(expiry_deadline(call), now(), :second), 1)}

          (call.routing_status == "waiting" and call.route_expires_at) &&
              DateTime.diff(now(), call.route_expires_at, :second) <= 15 ->
            Routing.enqueue_waiting(call)
            {:not_due, 5}

          true ->
            expire_call!(call)

            :expired
        end
      end,
      5_000
    )
  end

  def claim_cleanup(id, caller) do
    worker_transaction(:telephony_cleanup, caller, id, fn call ->
      cond do
        call.status in @active -> {:not_due, 5}
        not is_nil(call.cleanup_completed_at) -> :already_clean
        lease_active?(call.cleanup_claimed_at, 30) -> {:not_due, 5}
        true -> call |> update!(%{cleanup_claimed_at: now()}) |> command()
      end
    end)
  end

  def complete_cleanup(id, result, caller) do
    worker_transaction(
      :telephony_cleanup,
      caller,
      id,
      fn call ->
        result =
          cond do
            call.status in @active ->
              {:error, :telephony_cleanup_not_due}

            not is_nil(call.cleanup_completed_at) ->
              :ok

            result == :execute ->
              ProviderControlPort.cleanup_call(command(call))

            result == :ok and (map_size(call.pbx_state) > 0 or not is_nil(call.route_id)) ->
              {:error, :telephony_pbx_binding_invalid}

            true ->
              result
          end

        case result do
          :ok ->
            if call.dispatch_status == :dispatching and
                 lease_active?(call.dispatch_claimed_at, @cleanup_horizon_seconds) do
              update!(call, %{cleanup_claimed_at: nil})
              {:not_due, 5}
            else
              update!(call, %{cleanup_completed_at: now(), cleanup_claimed_at: nil})
              :cleaned
            end

          {:error, reason} ->
            update!(call, %{cleanup_claimed_at: nil})
            {:cleanup_error, reason}
        end
      end,
      if(result == :execute, do: 25_000, else: 0)
    )
    |> case do
      {:ok, :cleaned} -> :ok
      {:ok, {:cleanup_error, reason}} -> {:error, reason}
      other -> other
    end
  end

  def expire_route(id, caller) do
    worker_transaction(:telephony_routing, caller, id, fn call ->
      if call.status in @active and call.routing_status == "waiting",
        do: finish!(call, :no_answer, "queue_expired")

      :expired
    end)
  end

  def revoke_identity_access(%CommsCore.Accounts.CallLifecycleCommand{} = command) do
    if Repo.in_transaction?() do
      query = from(c in Call, where: c.tenant_id == ^command.tenant_id and c.status in ^@active)

      query =
        case command.operation do
          :sessions_revoked -> where(query, [c], c.answer_session_id in ^command.session_ids)
          :device_revoked -> where(query, [c], c.answer_device_id == ^command.device_id)
          :user_access_revoked -> where(query, [c], c.user_id == ^command.user_id)
        end

      {:ok,
       %CommsCore.Accounts.CallLifecycleReceipt{
         revoked_participant_count: revoke_query!(query, command.reason)
       }}
    else
      {:error, :transaction_required}
    end
  end

  def revoke_tenant_media(%CommsCore.Administration.CallLifecycleCommand{} = command) do
    if Repo.in_transaction?() do
      count =
        if command.media_kind == :audio do
          revoke_query!(
            from(c in Call, where: c.tenant_id == ^command.tenant_id and c.status in ^@active),
            command.reason
          )
        else
          0
        end

      {:ok, %CommsCore.Administration.CallLifecycleReceipt{revoked_participant_count: count}}
    else
      {:error, :transaction_required}
    end
  end

  defp revoke_query!(query, reason) do
    calls = Repo.all(from(c in query, order_by: [asc: c.id], lock: "FOR UPDATE"))
    Enum.each(calls, &finish!(&1, :ended, reason))
    length(calls)
  end

  defp config_view(grant, admin?) do
    number = Repo.get_by(Number, tenant_id: grant.tenant_id)

    route =
      if number,
        do: Repo.get_by(CommsCore.Telephony.Route, number_id: number.id, enabled: true),
        else: nil

    route_member = route && grant.user_id in route.member_ids

    visible =
      if number && (admin? or number.user_id == grant.user_id or route_member),
        do: number,
        else: nil

    fields = [:id, :phone_number, :extension, :user_id]
    fields = if admin?, do: fields ++ [:inbound_trunk_id, :outbound_trunk_id], else: fields

    %{
      configured: not is_nil(visible),
      number: if(visible, do: Map.take(visible, fields), else: nil),
      can_manage: grant.role in [:owner, :admin]
    }
  end

  defp access(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} -> {:ok, grant}
      _ -> {:error, :forbidden}
    end
  end

  defp lock_access!(subject, additional_user_ids \\ []) do
    with {:ok, initial} <- access(subject),
         {:ok, _policy} <- Administration.lock_call_policy(initial.tenant_id),
         {:ok, _users} <-
           Accounts.lock_active_human_directory_users(initial.tenant_id, [
             initial.user_id | additional_user_ids
           ]),
         {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} <-
           Accounts.lock_access_grant(subject) do
      grant
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp lock_tenant!(tenant_id) do
    case Administration.lock_call_policy(tenant_id) do
      {:ok, %{allow_audio_calls: true}} -> :ok
      {:ok, _} -> Repo.rollback(:audio_calls_disabled)
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp require_human!(tenant_id, user_id) do
    case Accounts.lock_active_human_directory_users(tenant_id, [user_id]) do
      {:ok, [_]} -> :ok
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp assigned_number!(grant) do
    case Routing.effective_number(grant) do
      %Number{} = number -> number
      _ -> Repo.rollback(:telephony_not_configured)
    end
  end

  defp own_call!(id, grant) do
    case Repo.one(
           from(c in Call,
             where:
               c.id == ^id and c.tenant_id == ^grant.tenant_id and
                 c.routing_status not in ["waiting", "voicemail"] and
                 (c.user_id == ^grant.user_id or
                    (c.status == :ringing and c.routing_status == "offered" and
                       ^grant.user_id in c.offered_user_ids)),
             lock: "FOR UPDATE"
           )
         ) do
      %Call{} = call -> call
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_call!(id) do
    case Repo.one(from(c in Call, where: c.id == ^id, lock: "FOR UPDATE")) do
      %Call{} = call -> call
      _ -> Repo.rollback(:not_found)
    end
  end

  defp inbound!(event) do
    if event.event_type not in [
         "participant_joined",
         "participant_left",
         "participant_connection_aborted"
       ] or event.participant_kind != :sip or
         not is_binary(event.trunk_id) or not is_binary(event.to_number) or
         not String.starts_with?(event.room, "kc_tel_inbound_"),
       do: Repo.rollback(:unrelated_provider_event)

    number = Repo.get_by(Number, phone_number: event.to_number, inbound_trunk_id: event.trunk_id)
    if is_nil(number), do: Repo.rollback(:unrelated_provider_event)
    lock_key!("assignment:" <> number.tenant_id)
    number = Repo.get_by(Number, phone_number: event.to_number, inbound_trunk_id: event.trunk_id)
    if is_nil(number), do: Repo.rollback(:unrelated_provider_event)

    eligible? =
      with {:ok, %{allow_audio_calls: true}} <- Administration.lock_call_policy(number.tenant_id),
           do: true

    routing = Routing.admission(number)

    eligible? =
      eligible? == true and routing.eligible and value(event, :admission_enabled) != false

    lock_key!("user:" <> number.tenant_id <> ":" <> routing.user_id)
    timestamp = now()

    busy? =
      routing.routing_status != "waiting" and active_user_call?(number.tenant_id, routing.user_id)

    status =
      cond do
        not eligible? -> :failed
        room_ended?(event.room) -> :no_answer
        event.event_type == "participant_left" -> :no_answer
        event.event_type == "participant_connection_aborted" -> :failed
        busy? -> :busy
        true -> :ringing
      end

    terminal? = status not in @active

    call =
      insert_call!(number, %{
        id: Ecto.UUID.generate(),
        user_id: routing.user_id,
        route_id: routing.route_id,
        routing_status: routing.routing_status,
        offered_user_ids: routing.offered_user_ids,
        route_expires_at: routing.route_expires_at,
        direction: :inbound,
        from_number: event.from_number || "Unknown",
        to_number: number.phone_number,
        provider_room: event.room,
        provider_identity: event.participant_identity,
        provider_call_id: event.provider_call_id,
        dispatch_status: :pending,
        status: status,
        ended_at: if(terminal?, do: timestamp, else: nil),
        end_reason: if(terminal?, do: "initial_" <> Atom.to_string(status), else: nil),
        started_at: timestamp,
        expires_at:
          if(routing.routing_status == "waiting",
            do: routing.route_expires_at,
            else: DateTime.add(timestamp, ring_seconds(), :second)
          )
      })

    Routing.enqueue_waiting(call)
    enqueue!(:telephony_expiry, call.id, call.expires_at)
    if terminal?, do: enqueue!(:telephony_cleanup, call.id)
    publish!(call)
    call
  end

  defp event_matches?(call, event) do
    event.event_type == "room_finished" or
      (event.participant_identity in [call.provider_identity, call.app_identity] and
         not is_nil(event.participant_identity) and
         (is_nil(event.provider_call_id) or is_nil(call.provider_call_id) or
            event.provider_call_id == call.provider_call_id) and
         (is_nil(event.trunk_id) or event.trunk_id == call.inbound_trunk_id or
            event.trunk_id == call.outbound_trunk_id))
  end

  defp apply_event!(call, event) do
    if (provider_handoff?(call) or provider_capture?(call)) and
         event.event_type in [
           "participant_left",
           "participant_connection_aborted",
           "room_finished"
         ] do
      # The app/SIP disappearance is expected after an ARI handoff. The original
      # externally bound leg, not the LiveKit room, establishes its remote end.
      CallMonitor.enqueue_bound_call_monitor!(call)
      call
    else
      apply_room_event!(call, event)
    end
  end

  defp apply_room_event!(call, event) do
    case event.event_type do
      "participant_joined" when event.participant_identity == call.app_identity ->
        app_joined!(call, event)

      "answered" when call.direction == :outbound ->
        answer_connected!(call)

      "participant_left" when event.participant_identity == call.app_identity ->
        app_left!(call, event)

      "participant_left" ->
        {status, reason} = unanswered_outcome(call, "participant_left")
        finish!(call, status, reason)

      "participant_connection_aborted" ->
        finish!(call, :failed, "connection_aborted")

      "room_finished" ->
        {status, reason} = unanswered_outcome(call, "room_finished")
        finish!(call, status, reason)

      "provider_failed" ->
        finish!(call, :failed, "provider_failed")

      _ ->
        call
    end
  end

  defp app_joined!(call, event) do
    require_app_epoch!(event)

    if stale_app_event?(call, event) or app_epoch_closed?(call.id, event.participant_sid) do
      call
    else
      if not is_nil(call.app_connected_at) and not is_nil(call.app_event_at) and
           event.participant_sid != call.app_provider_sid and
           DateTime.compare(event.occurred_at, call.app_event_at) == :eq do
        update!(call, %{app_pending_sid: event.participant_sid, app_pending_at: event.occurred_at})
      else
        updated =
          update!(call, %{
            app_connected_at: call.app_connected_at || now(),
            app_reconnect_deadline: nil,
            app_provider_sid: event.participant_sid,
            app_event_at: event.occurred_at,
            app_pending_sid: nil,
            app_pending_at: nil
          })

        if call.direction == :inbound, do: enqueue!(:telephony_dispatch, call.id)
        updated
      end
    end
  end

  defp app_left!(call, event) do
    require_app_epoch!(event)

    cond do
      event.participant_sid == call.app_pending_sid ->
        update!(call, %{app_pending_sid: nil, app_pending_at: nil})

      stale_app_event?(call, event) ->
        call

      is_nil(call.app_provider_sid) and call.status == :ringing ->
        call =
          update!(call, %{app_left_sid: event.participant_sid, app_event_at: event.occurred_at})

        {status, reason} = unanswered_outcome(call, "participant_left")
        finish!(call, status, reason)

      event.participant_sid != call.app_provider_sid ->
        call

      not is_nil(call.app_pending_sid) and not app_epoch_closed?(call.id, call.app_pending_sid) ->
        updated =
          update!(call, %{
            app_provider_sid: call.app_pending_sid,
            app_event_at: latest_time(event.occurred_at, call.app_pending_at),
            app_left_sid: event.participant_sid,
            app_connected_at: now(),
            app_reconnect_deadline: nil,
            app_pending_sid: nil,
            app_pending_at: nil
          })

        publish!(updated)
        updated

      call.status != :answered ->
        {status, reason} = unanswered_outcome(call, "participant_left")
        finish!(call, status, reason)

      true ->
        deadline =
          call.app_reconnect_deadline ||
            earliest_expiry(DateTime.add(now(), 30, :second), call.expires_at)

        updated =
          update!(call, %{
            app_connected_at: nil,
            app_reconnect_deadline: deadline,
            app_left_sid: event.participant_sid,
            app_event_at: event.occurred_at
          })

        enqueue!(:telephony_expiry, call.id, deadline)
        publish!(updated)
        updated
    end
  end

  defp require_app_epoch!(event) do
    if not bounded_string?(event.participant_sid, 200) or
         not match?(%DateTime{}, event.occurred_at),
       do: Repo.rollback(:invalid_provider_event)
  end

  defp stale_app_event?(%Call{app_event_at: nil}, _event), do: false

  defp stale_app_event?(call, event),
    do: DateTime.compare(event.occurred_at, call.app_event_at) == :lt

  defp app_epoch_closed?(call_id, sid) do
    Repo.exists?(
      from(e in ProviderEvent,
        where:
          e.call_id == ^call_id and e.participant_sid == ^sid and
            e.event_type in ["participant_left", "participant_connection_aborted"]
      )
    )
  end

  defp latest_time(first, second),
    do: if(DateTime.compare(first, second) == :lt, do: second, else: first)

  defp authorized_call?(call) do
    with {:ok, %{allow_audio_calls: true}} <- Administration.lock_call_policy(call.tenant_id),
         {:ok, [_]} <- Accounts.lock_active_human_directory_users(call.tenant_id, [call.user_id]) do
      if call.answer_session_id do
        match?(
          {:ok, %AccessGrant{account_type: :human, access_scope: :workspace}},
          Accounts.lock_access_grant(%{
            tenant_id: call.tenant_id,
            user_id: call.user_id,
            device_id: call.answer_device_id,
            session_id: call.answer_session_id
          })
        )
      else
        true
      end
    else
      _ -> false
    end
  end

  defp answer_connected!(%Call{status: :answered} = call), do: call

  defp answer_connected!(call) do
    timestamp = now()

    {:ok, grant} =
      Accounts.lock_access_grant(%{
        tenant_id: call.tenant_id,
        user_id: call.user_id,
        device_id: call.answer_device_id,
        session_id: call.answer_session_id
      })

    call =
      update!(call, %{
        status: :answered,
        answered_at: timestamp,
        expires_at:
          earliest_expiry(
            DateTime.add(timestamp, maximum_seconds(), :second),
            grant.effective_expires_at
          )
      })

    enqueue!(:telephony_expiry, call.id, call.expires_at)
    publish!(call)
    call
  end

  defp finish!(call, status, reason) do
    call = update!(call, %{status: status, ended_at: now(), end_reason: reason})
    enqueue!(:telephony_cleanup, call.id)
    publish!(call)
    call
  end

  defp request_cleanup!(call) do
    update!(call, %{cleanup_completed_at: nil})
    enqueue!(:telephony_cleanup, call.id)
  end

  defp insert_call!(number, attrs) do
    base = %{
      tenant_id: number.tenant_id,
      number_id: number.id,
      extension: number.extension,
      inbound_trunk_id: number.inbound_trunk_id,
      outbound_trunk_id: number.outbound_trunk_id
    }

    case %Call{} |> Call.changeset(Map.merge(base, attrs)) |> Repo.insert() do
      {:ok, call} -> call
      {:error, changeset} -> rollback_validation!(changeset)
    end
  end

  defp update!(call, attrs), do: call |> Call.changeset(attrs) |> Repo.update!()

  defp record_event!(call, event) do
    %ProviderEvent{}
    |> ProviderEvent.changeset(%{
      tenant_id: call.tenant_id,
      call_id: call.id,
      event_id: event.event_id,
      event_type: event.event_type,
      participant_sid: event.participant_sid,
      occurred_at: event.occurred_at
    })
    |> Repo.insert!()
  end

  defp view(call, grant) do
    active? = call.status in @active and not due?(call)

    owns_device? =
      grant && call.answer_session_id == grant.session_id &&
        call.answer_device_id == grant.device_id

    owns_device? = owns_device? == true
    unclaimed? = is_nil(call.answer_session_id)

    duration =
      if call.answered_at,
        do: max(DateTime.diff(call.ended_at || now(), call.answered_at, :second), 0),
        else: 0

    %CallView{
      id: call.id,
      direction: call.direction,
      status: call.status,
      from_number: call.from_number,
      to_number: call.to_number,
      extension: call.extension,
      started_at: call.started_at,
      answered_at: call.answered_at,
      ended_at: call.ended_at,
      end_reason: call.end_reason,
      control_state: call.control_state,
      connected_seconds: duration,
      can_answer:
        not is_nil(grant) and active? and call.direction == :inbound and call.status == :ringing and
          unclaimed? and Routing.visible_offer?(call, grant),
      can_join:
        not is_nil(grant) and active? and call.control_state not in ["transferred", "voicemail"] and
          not provider_handoff?(call) and not provider_capture?(call) and
          (owns_device? or (unclaimed? and call.direction == :outbound)),
      can_end: not is_nil(grant) and active? and (unclaimed? or owns_device?),
      active_on_this_device: active? and owns_device?
    }
  end

  defp command(call) do
    %ProviderCommand{
      call_id: call.id,
      tenant_id: call.tenant_id,
      route_id: call.route_id,
      provider_room: call.provider_room,
      provider_identity: call.provider_identity,
      direction: call.direction,
      status: call.status,
      from_number: call.from_number,
      to_number: call.to_number,
      inbound_trunk_id: call.inbound_trunk_id,
      outbound_trunk_id: call.outbound_trunk_id,
      pbx_state: call.pbx_state,
      control_state: call.control_state,
      expires_at: call.expires_at
    }
  end

  defp provider_capture?(call) do
    map_size(call.pbx_state) > 0 and
      (call.control_state == "voicemail" or
         Repo.exists?(
           from(c in ControlCommand,
             where:
               c.call_id == ^call.id and c.tenant_id == ^call.tenant_id and
                 c.action == :voicemail and not is_nil(c.claimed_at) and
                 not is_nil(c.notice_completed_at) and c.status in [:dispatching, :unknown]
           )
         ))
  end

  defp provider_handoff?(call) do
    map_size(call.pbx_state) > 0 and
      (call.control_state == "transferred" or
         Repo.exists?(
           from(c in ControlCommand,
             where:
               c.call_id == ^call.id and c.tenant_id == ^call.tenant_id and
                 c.action == :complete_transfer and not is_nil(c.claimed_at) and
                 c.status in [:dispatching, :unknown]
           )
         ))
  end

  defp valid_answer_result?(call, details) when is_map(details) do
    provider_call_id = value(details, :provider_call_id)

    value(details, :state) == :answered and bounded_string?(provider_call_id, 200) and
      (is_nil(call.provider_call_id) or call.provider_call_id == provider_call_id) and
      (is_nil(value(details, :provider_room)) or
         value(details, :provider_room) == call.provider_room) and
      (is_nil(value(details, :provider_identity)) or
         value(details, :provider_identity) == call.provider_identity)
  end

  defp valid_answer_result?(_call, _details), do: false

  defp correlate_late_answer!(call, {:ok, details}) do
    if valid_answer_result?(call, details) do
      update!(call, %{
        provider_call_id: value(details, :provider_call_id),
        dispatch_status: :started
      })
    else
      call
    end
  end

  defp correlate_late_answer!(call, _result), do: call

  defp expire_call!(call) do
    {status, default_reason} = unanswered_outcome(call, "ring_timeout")

    reason =
      cond do
        is_nil(call.answered_at) ->
          default_reason

        call.app_reconnect_deadline && DateTime.compare(call.app_reconnect_deadline, now()) != :gt ->
          "app_reconnect_timeout"

        true ->
          "maximum_duration"
      end

    finish!(call, status, reason)
  end

  defp unanswered_outcome(call, reason) do
    cond do
      not is_nil(call.answered_at) ->
        {:ended, reason}

      call.direction == :inbound and not is_nil(call.answer_session_id) and
          not is_nil(call.app_connected_at) ->
        {:failed, "answer_unconfirmed"}

      true ->
        {:no_answer, reason}
    end
  end

  defp tombstone_room!(room) do
    lock_key!("room-tombstone-capacity")
    timestamp = now()
    Repo.delete_all(from(t in RoomTombstone, where: t.expires_at <= ^timestamp))
    hash = room_hash(room)
    existing = Repo.get_by(RoomTombstone, room_hash: hash)

    if existing do
      :ok
    else
      if Repo.aggregate(RoomTombstone, :count) >= 10_000,
        do: Repo.rollback(:telephony_tombstone_capacity)

      %RoomTombstone{}
      |> RoomTombstone.changeset(%{
        room_hash: hash,
        expires_at: DateTime.add(timestamp, 86_400, :second)
      })
      |> Repo.insert!()

      :ok
    end
  end

  defp room_ended?(room) do
    timestamp = now()
    hash = room_hash(room)

    Repo.exists?(
      from(t in RoomTombstone, where: t.room_hash == ^hash and t.expires_at > ^timestamp)
    )
  end

  defp room_hash(room), do: :crypto.hash(:sha256, room) |> Base.encode16(case: :lower)

  defp expiry_deadline(%Call{control_state: "transferred"} = call), do: call.expires_at

  defp expiry_deadline(%Call{pbx_state: saved} = call) when map_size(saved) > 0 do
    cond do
      provider_capture?(call) ->
        case Mailboxes.capture_lifecycle(call) do
          {:pending, deadline} -> earliest_expiry(call.expires_at, deadline)
          _ -> now()
        end

      provider_handoff?(call) ->
        call.expires_at

      true ->
        earliest_expiry(call.expires_at, call.app_reconnect_deadline)
    end
  end

  defp expiry_deadline(%Call{app_reconnect_deadline: nil} = call), do: call.expires_at
  defp expiry_deadline(call), do: earliest_expiry(call.expires_at, call.app_reconnect_deadline)
  defp due?(call), do: DateTime.compare(expiry_deadline(call), now()) != :gt

  defp publish!(call) do
    Outbox.insert_and_enqueue!(%{
      tenant_id: call.tenant_id,
      event_type: "telephony.call.updated",
      aggregate_type: "telephony_call",
      aggregate_id: call.id,
      payload: %{call_id: call.id, user_id: call.user_id, status: Atom.to_string(call.status)},
      available_at: now()
    })
  end

  defp audit!(tenant_id, user_id, action, id, metadata) do
    case Audit.record(%{
           tenant_id: tenant_id,
           actor_user_id: user_id,
           action: action,
           resource_type: "telephony_number",
           resource_id: id,
           metadata: metadata
         }) do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback(:audit_failed)
    end
  end

  defp enqueue!(kind, id, scheduled_at \\ nil) do
    queue = if kind == :telephony_dispatch, do: :telephony, else: :lifecycle
    opts = [worker: RuntimePorts.job_worker_name!(kind), queue: queue, max_attempts: 100]
    opts = if scheduled_at, do: Keyword.put(opts, :scheduled_at, scheduled_at), else: opts
    %{"call_id" => id} |> Oban.Job.new(opts) |> Repo.insert!()
  end

  defp worker_transaction(kind, caller, id, function, effect_budget \\ 0) do
    if RuntimePorts.authorized_job_worker?(kind, caller) do
      with {:ok, id} <- uuid(id) do
        timeout = if kind in [:telephony_cleanup, :telephony_expiry], do: 35_000, else: 15_000
        deadline = System.monotonic_time(:millisecond) + timeout

        transaction(
          fn ->
            snapshot = Repo.get(Call, id)
            if is_nil(snapshot), do: Repo.rollback(:not_found)

            authorized? =
              kind != :telephony_dispatch or snapshot.status not in @active or
                authorized_call?(snapshot)

            call = lock_call!(id)

            if effect_budget > 0 and
                 deadline - System.monotonic_time(:millisecond) < effect_budget + 3_000,
               do: Repo.rollback(:telephony_provider_unavailable)

            if not authorized? and call.status in @active do
              finish!(call, :failed, "access_revoked")
              :already_terminal
            else
              function.(call)
            end
          end,
          timeout
        )
      end
    else
      {:error, :forbidden}
    end
  end

  defp active_user_call?(tenant_id, user_id),
    do:
      Repo.exists?(
        from(c in Call,
          where:
            c.tenant_id == ^tenant_id and c.user_id == ^user_id and c.status in ^@active and
              c.routing_status not in ["waiting", "voicemail"]
        )
      )

  defp lease_active?(nil, _seconds), do: false
  defp lease_active?(timestamp, seconds), do: DateTime.diff(now(), timestamp, :second) < seconds

  defp lock_key!(key),
    do:
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "telephony:" <> key
      ])

  defp transaction(fun, timeout \\ 15_000), do: Repo.transaction(fun, timeout: timeout)
  defp unwrap_created({:ok, {view, disposition}}), do: {:ok, view, disposition}
  defp unwrap_created(other), do: other
  defp unwrap_credential({:ok, {view, credential}}), do: {:ok, view, credential}
  defp unwrap_credential(other), do: other
  defp unwrap_event({:ok, {view, disposition}}), do: {:ok, view, disposition}
  defp unwrap_event(other), do: other

  defp rollback_validation!(changeset) do
    {:ok, error} = ValidationError.from(changeset)
    Repo.rollback(error)
  end

  defp validate_event(event) when is_map(event) do
    normalized =
      Map.new(
        [
          :event_id,
          :event_type,
          :room,
          :participant_identity,
          :participant_sid,
          :participant_kind,
          :provider_call_id,
          :trunk_id,
          :from_number,
          :to_number,
          :occurred_at,
          :admission_enabled
        ],
        &{&1, value(event, &1)}
      )

    cond do
      not bounded_string?(normalized.event_id, 200) ->
        {:error, :invalid_provider_event}

      normalized.event_type not in @event_types ->
        {:error, :invalid_provider_event}

      not bounded_string?(normalized.room, 200) ->
        {:error, :invalid_provider_event}

      normalized.event_type != "room_finished" and
          not bounded_string?(normalized.participant_identity, 200) ->
        {:error, :invalid_provider_event}

      normalized.from_number && not bounded_string?(normalized.from_number, 40) ->
        {:error, :invalid_provider_event}

      true ->
        {:ok, normalized}
    end
  end

  defp validate_event(_), do: {:error, :invalid_provider_event}

  defp bounded_string?(value, limit),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= limit

  defp phone(value) do
    if is_binary(value) and Regex.match?(~r/^\+[1-9][0-9]{7,14}$/, value),
      do: {:ok, value},
      else: {:error, :invalid_destination}
  end

  defp idempotency_key(value),
    do:
      if(bounded_string?(value, 100), do: {:ok, value}, else: {:error, :idempotency_key_required})

  defp reason(attrs),
    do:
      if(
        bounded_string?(value(attrs, :reason), 500) and
          String.length(String.trim(value(attrs, :reason))) >= 3,
        do: :ok,
        else: {:error, :reason_required}
      )

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp parse_scope(nil), do: {:ok, :all}
  defp parse_scope(scope) when scope in ["all", :all, "recent", :recent], do: {:ok, :all}
  defp parse_scope(scope) when scope in ["active", :active], do: {:ok, :active}
  defp parse_scope(scope) when scope in ["missed", :missed], do: {:ok, :missed}
  defp parse_scope(_), do: {:error, :invalid_call_scope}
  defp parse_limit(value) when is_integer(value), do: min(max(value, 1), 100)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_limit(number)
      _ -> 30
    end
  end

  defp parse_limit(_), do: 30
  defp parse_cursor(nil), do: {:ok, nil}
  defp parse_cursor(""), do: {:ok, nil}

  defp parse_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [time, id] <- String.split(decoded, "|", parts: 2),
         {:ok, timestamp, 0} <- DateTime.from_iso8601(time),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {timestamp, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp parse_cursor(_), do: {:error, :invalid_cursor}

  defp cursor_for(call),
    do: Base.url_encode64(DateTime.to_iso8601(call.started_at) <> "|" <> call.id, padding: false)

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_), do: "failure"

  defp app_identity(id, device_id),
    do: "kc_tel_app_" <> String.replace(id, "-", "") <> "_" <> String.replace(device_id, "-", "")

  defp ring_seconds, do: Application.get_env(:comms_core, :telephony_ring_timeout_seconds, 45)

  defp maximum_seconds,
    do: Application.get_env(:comms_core, :telephony_max_duration_seconds, 1800)

  defp earliest_expiry(first, nil), do: first

  defp earliest_expiry(first, second),
    do: if(DateTime.compare(first, second) == :lt, do: first, else: second)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
