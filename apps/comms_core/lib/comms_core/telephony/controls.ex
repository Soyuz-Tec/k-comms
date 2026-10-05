defmodule CommsCore.Telephony.Controls do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Administration, Outbox, Repo, RuntimePorts}
  alias CommsCore.Accounts.AccessGrant

  alias CommsCore.Telephony.{
    Call,
    ControlCommand,
    ControlRequest,
    ControlView,
    Ivr,
    ProviderControlPort
  }

  @actions %{
    "dtmf" => :dtmf,
    "hold" => :hold,
    "resume" => :resume,
    "blind_transfer" => :blind_transfer,
    "consult_transfer" => :consult_transfer,
    "complete_transfer" => :complete_transfer,
    "cancel_transfer" => :cancel_transfer,
    "voicemail" => :voicemail
  }
  @limit 500
  @worker_transaction_budget_ms 30_000
  @provider_effect_budget_ms 15_000
  @effect_commit_reserve_ms 3_000

  @doc false
  @spec rollback_control_hazard_count() :: non_neg_integer()
  def rollback_control_hazard_count() do
    commands =
      Repo.aggregate(
        from(c in ControlCommand, where: c.status in [:pending, :dispatching, :unknown]),
        :count
      )

    calls =
      Repo.aggregate(
        from(c in Call,
          where:
            (c.status in [:ringing, :answered] or is_nil(c.cleanup_completed_at)) and
              (c.control_state != "connected" or c.routing_status != "individual" or
                 fragment("? <> '{}'::jsonb", c.pbx_state))
        ),
        :count
      )

    commands + calls
  end

  def capabilities(subject) do
    with {:ok, _} <- access(subject), do: {:ok, ProviderControlPort.capabilities()}
  end

  def list(id, subject) do
    with {:ok, grant} <- access(subject),
         {:ok, id} <- uuid(id),
         %Call{} <-
           Repo.one(
             from(c in Call,
               where:
                 c.id == ^id and c.tenant_id == ^grant.tenant_id and c.user_id == ^grant.user_id
             )
           ) do
      commands =
        Repo.all(
          from(c in ControlCommand,
            where: c.call_id == ^id and c.tenant_id == ^grant.tenant_id,
            order_by: [desc: c.inserted_at, desc: c.id],
            limit: 100
          )
        )

      {:ok, %{commands: Enum.map(commands, &view/1), limit: 100}}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def request(id, attrs, subject) do
    with {:ok, initial} <- access(subject),
         {:ok, id} <- uuid(id),
         {:ok, action} <- action(value(attrs, :action)),
         {:ok, key} <- key(value(attrs, :idempotency_key)),
         {:ok, payload} <- payload(action, attrs) do
      Repo.transaction(fn ->
        if action == :voicemail do
          snapshot =
            Repo.get_by(Call, id: id, tenant_id: initial.tenant_id, user_id: initial.user_id)

          if is_nil(snapshot), do: Repo.rollback(:not_found)
          CommsCore.Telephony.Mailboxes.lock_capture_effect_policy!(snapshot)
        end

        grant = lock_access!(subject)
        call = own_call!(id, grant)
        require_owner!(call, grant)
        fingerprint_key = Application.get_env(:comms_core, :telephony_control_fingerprint_key)

        if not is_binary(fingerprint_key) or byte_size(fingerprint_key) < 32,
          do: Repo.rollback(:telephony_control_unavailable)

        hash =
          Base.encode16(
            :crypto.mac(
              :hmac,
              :sha256,
              fingerprint_key,
              Atom.to_string(action) <> ":" <> payload
            ),
            case: :lower
          )

        previous = Repo.get_by(ControlCommand, call_id: call.id, idempotency_key: key)

        if previous do
          if previous.payload_hash != hash or previous.action != action,
            do: Repo.rollback(:idempotency_conflict)

          view(previous)
        else
          if call.status != :answered or DateTime.compare(call.expires_at, now()) != :gt,
            do: Repo.rollback(:invalid_call_action)

          if not (get_in(ProviderControlPort.capabilities(), [action, :supported]) == true),
            do: Repo.rollback(:telephony_control_unsupported)

          require_state!(call, action)

          if action in [:blind_transfer, :consult_transfer] do
            case ProviderControlPort.authorize_destination(payload) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          if Repo.aggregate(from(c in ControlCommand, where: c.call_id == ^call.id), :count) >=
               @limit,
             do: Repo.rollback(:telephony_control_limit)

          unresolved =
            Repo.all(
              from(c in ControlCommand,
                where:
                  c.call_id == ^call.id and c.status in [:pending, :dispatching, :unknown] and
                    c.action != :dtmf,
                lock: "FOR UPDATE"
              )
            )

          case {action, unresolved} do
            {:cancel_transfer,
             [
               %ControlCommand{action: :consult_transfer, status: :unknown, claimed_at: claimed} =
                   previous
             ]}
            when not is_nil(claimed) ->
              if previous.session_id != grant.session_id or previous.device_id != grant.device_id or
                   previous.user_id != grant.user_id or map_size(call.pbx_state || %{}) == 0,
                 do: Repo.rollback(:telephony_control_conflict)

              # This retires the uncertain forward operation, not its provider
              # effects. The new durable cancel must confirm exact-leg cleanup
              # and resume before the call's control state changes.
              update!(previous, %{
                status: :failed,
                completed_at: now(),
                failure_reason: "superseded_by_cancel"
              })

            {_, []} ->
              :ok

            _ ->
              Repo.rollback(:telephony_control_conflict)
          end

          timestamp = now()

          attributes = %{
            tenant_id: grant.tenant_id,
            call_id: call.id,
            user_id: grant.user_id,
            session_id: grant.session_id,
            device_id: grant.device_id,
            action: action,
            status: if(action == :dtmf, do: :dispatching, else: :pending),
            idempotency_key: key,
            payload_hash: hash,
            destination:
              if(action in [:blind_transfer, :consult_transfer], do: payload, else: nil),
            claimed_at: if(action == :dtmf, do: timestamp, else: nil),
            expires_at: DateTime.add(timestamp, 60, :second)
          }

          command =
            %ControlCommand{} |> ControlCommand.changeset(attributes) |> insert_or_rollback()

          if action == :voicemail, do: CommsCore.Telephony.Mailboxes.reserve!(call)
          if action != :dtmf, do: enqueue!(command.id)
          publish!(command)
          view(command, action == :dtmf)
        end
      end)
    end
  end

  # Only the owning browser can acknowledge its single-use SDK instruction.
  # This receipt is submission evidence, not a provider/carrier acknowledgment.
  def complete_browser(id, command_id, attrs, subject) do
    with {:ok, _} <- access(subject),
         {:ok, id} <- uuid(id),
         {:ok, command_id} <- uuid(command_id),
         result when result in ["submitted", "unknown"] <- value(attrs, :status) do
      Repo.transaction(fn ->
        grant = lock_access!(subject)
        call = own_call!(id, grant)
        require_owner!(call, grant)
        command = lock_command!(command_id, call.id)

        if command.action != :dtmf or command.session_id != grant.session_id or
             command.device_id != grant.device_id,
           do: Repo.rollback(:forbidden)

        cond do
          command.status in [:submitted, :unknown, :failed] ->
            view(command)

          command.status != :dispatching ->
            Repo.rollback(:invalid_call_action)

          DateTime.compare(command.expires_at, now()) != :gt ->
            command
            |> update!(%{
              status: :unknown,
              completed_at: now(),
              failure_reason: "submission_deadline"
            })
            |> view()

          true ->
            command
            |> update!(%{
              status: if(result == "submitted", do: :submitted, else: :unknown),
              completed_at: now(),
              failure_reason: if(result == "unknown", do: "sdk_outcome_unknown", else: nil)
            })
            |> view()
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_call_action}
    end
  end

  def claim(id, caller) do
    worker(id, caller, fn command, call, _deadline ->
      cond do
        command.status == :dispatching and command.action == :blind_transfer ->
          update!(command, %{
            status: :unknown,
            completed_at: now(),
            failure_reason: "worker_restarted_after_claim"
          })

          :already_claimed

        command.status == :dispatching and DateTime.compare(command.expires_at, now()) != :gt ->
          update!(command, %{
            status: :unknown,
            completed_at: now(),
            failure_reason: "control_authorization_expired"
          })

          :already_complete

        command.status == :dispatching ->
          if call.status != :answered and not system_voicemail?(command, call),
            do: Repo.rollback(:forbidden)

          request_view(command, call, true)

        command.status != :pending ->
          :already_complete

        (call.status != :answered and not system_voicemail?(command, call)) or
          DateTime.compare(call.expires_at, now()) != :gt or
            DateTime.compare(command.expires_at, now()) != :gt ->
          update!(command, %{
            status: :failed,
            completed_at: now(),
            failure_reason: "call_unavailable"
          })

          :already_complete

        not (get_in(ProviderControlPort.capabilities(), [command.action, :supported]) == true) ->
          update!(command, %{
            status: :failed,
            completed_at: now(),
            failure_reason: "capability_revoked"
          })

          :already_complete

        true ->
          if command.action in [:blind_transfer, :consult_transfer] do
            case ProviderControlPort.authorize_destination(command.destination) do
              :ok -> :ok
              _ -> Repo.rollback(:telephony_destination_forbidden)
            end
          end

          update!(command, %{status: :dispatching, claimed_at: now()})
          request_view(command, call, false)
      end
    end)
  end

  def reconcile(id, command_id, subject) do
    with {:ok, initial} <- access(subject),
         {:ok, id} <- uuid(id),
         {:ok, command_id} <- uuid(command_id) do
      Repo.transaction(fn ->
        snapshot =
          Repo.get_by(Call, id: id, tenant_id: initial.tenant_id, user_id: initial.user_id)

        previous = Repo.get_by(ControlCommand, id: command_id, call_id: id)

        if snapshot && previous && previous.action == :voicemail,
          do: CommsCore.Telephony.Mailboxes.lock_capture_effect_policy!(snapshot)

        grant = lock_access!(subject)
        call = own_call!(id, grant)
        require_owner!(call, grant)
        command = lock_command!(command_id, call.id)

        if command.session_id != grant.session_id or command.device_id != grant.device_id,
          do: Repo.rollback(:forbidden)

        if command.action in [:dtmf, :blind_transfer] or command.status != :unknown or
             call.status != :answered,
           do: Repo.rollback(:invalid_call_action)

        command =
          update!(command, %{
            status: :dispatching,
            completed_at: nil,
            failure_reason: nil,
            expires_at: DateTime.add(now(), 60, :second)
          })

        enqueue!(command.id)
        view(command)
      end)
    end
  end

  def queue_voicemail(id, caller) do
    if RuntimePorts.authorized_job_worker?(:telephony_routing, caller) do
      with {:ok, id} <- uuid(id) do
        Repo.transaction(fn ->
          snapshot = Repo.get(Call, id)
          if is_nil(snapshot) or is_nil(snapshot.route_id), do: Repo.rollback(:not_found)
          ivr_deadline = Ivr.original_deadline(id)

          if ivr_deadline &&
               (DateTime.compare(ivr_deadline, now()) != :gt or
                  DateTime.compare(snapshot.expires_at, now()) != :gt),
             do: Repo.rollback(:call_ended)

          CommsCore.Telephony.Mailboxes.lock_capture_effect_policy!(snapshot)

          case Administration.lock_call_policy(snapshot.tenant_id) do
            {:ok, %{allow_audio_calls: true}} -> :ok
            _ -> Repo.rollback(:audio_calls_disabled)
          end

          notice = CommsCore.Telephony.Mailboxes.reserve!(snapshot)
          message = Repo.get_by!(CommsCore.Telephony.Voicemail, call_id: id)
          call = Repo.one(from(c in Call, where: c.id == ^id, lock: "FOR UPDATE"))

          if call.status != :ringing or call.routing_status != "waiting",
            do: Repo.rollback(:call_ended)

          if ivr_deadline &&
               (DateTime.compare(ivr_deadline, now()) != :gt or
                  DateTime.compare(call.expires_at, now()) != :gt),
             do: Repo.rollback(:call_ended)

          capture_deadline =
            if ivr_deadline do
              [message.recording_deadline, call.expires_at, ivr_deadline] |> Enum.min(DateTime)
            else
              message.recording_deadline
            end

          if ivr_deadline do
            message
            |> CommsCore.Telephony.Voicemail.changeset(%{recording_deadline: capture_deadline})
            |> Repo.update!()
          end

          key = "queue-voicemail:" <> call.id
          previous = Repo.get_by(ControlCommand, call_id: call.id, idempotency_key: key)

          if is_nil(previous) do
            timestamp = now()

            call
            |> Call.changeset(%{
              routing_status: "voicemail",
              control_state: "voicemail",
              user_id: message.user_id,
              offered_user_ids: [],
              expires_at: capture_deadline
            })
            |> Repo.update!()

            attrs = %{
              tenant_id: call.tenant_id,
              call_id: call.id,
              user_id: message.user_id,
              action: :voicemail,
              status: :pending,
              idempotency_key: key,
              payload_hash: Base.encode16(:crypto.hash(:sha256, notice), case: :lower),
              expires_at:
                if(ivr_deadline,
                  do:
                    Enum.min([DateTime.add(timestamp, 60, :second), capture_deadline], DateTime),
                  else: DateTime.add(timestamp, 60, :second)
                )
            }

            command = %ControlCommand{} |> ControlCommand.changeset(attrs) |> insert_or_rollback()
            enqueue!(command.id)
            publish!(command)
          end

          :voicemail
        end)
      end
    else
      {:error, :forbidden}
    end
  end

  def provider_event(body, authorization) do
    with {:ok, event} <- ProviderControlPort.verify_event(body, authorization),
         {:ok, call_id} <- Ecto.UUID.cast(event.call_id) do
      Repo.transaction(fn ->
        call = Repo.one(from(c in Call, where: c.id == ^call_id, lock: "FOR UPDATE"))
        if is_nil(call), do: Repo.rollback(:not_found)

        command =
          Repo.one(
            from(c in ControlCommand,
              where:
                c.call_id == ^call_id and c.action == :voicemail and c.status == :dispatching,
              lock: "FOR UPDATE"
            )
          )

        if is_nil(command), do: Repo.rollback(:unrelated_provider_event)
        notice = CommsCore.Telephony.Mailboxes.notice_for_call(call.id)

        if call.pbx_state["external"] != event.channel_id or notice != event.media_uri or
             event.playback_id != "kc_notice_" <> String.replace(call.id, "-", ""),
           do: Repo.rollback(:invalid_provider_event)

        if is_nil(command.notice_completed_at),
          do: update!(command, %{notice_completed_at: now(), notice_event_id: event.event_id})

        :applied
      end)
    end
  end

  def bind(id, bindings, caller) when is_map(bindings) do
    worker(id, caller, fn command, call, _deadline ->
      if command.status != :dispatching, do: Repo.rollback(:invalid_call_action)

      required_bindings =
        if system_voicemail?(command, call),
          do: ["external", "mixing", "holding", "consult", "recording"],
          else: ["external", "app", "mixing", "holding", "consult", "recording"]

      safe =
        Enum.all?(required_bindings, fn key ->
          value = bindings[key]
          is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_.:-]{1,200}$/, value)
        end)

      if not safe, do: Repo.rollback(:telephony_pbx_binding_invalid)

      if map_size(call.pbx_state || %{}) != 0 and call.pbx_state != bindings,
        do: Repo.rollback(:telephony_pbx_binding_invalid)

      saved = call |> Call.changeset(%{pbx_state: bindings}) |> Repo.update!()

      request_view(
        command,
        saved,
        not is_nil(command.claimed_at) and DateTime.diff(now(), command.claimed_at, :second) > 5
      )
    end)
  end

  def complete(id, result, caller) do
    worker(id, caller, fn command, call, deadline ->
      cond do
        command.status != :dispatching ->
          :complete

        match?({:execute, _}, result) and
            ((call.status != :answered and not system_voicemail?(command, call)) or
               DateTime.compare(call.expires_at, now()) != :gt) ->
          update!(command, %{
            status: :failed,
            completed_at: now(),
            failure_reason: "call_unavailable"
          })

          :complete

        match?({:execute, _}, result) and DateTime.compare(command.expires_at, now()) != :gt ->
          update!(command, %{
            status: :unknown,
            completed_at: now(),
            failure_reason: "control_authorization_expired"
          })

          :complete

        true ->
          outcome =
            case result do
              {:execute, reconcile} when is_boolean(reconcile) ->
                # Identity, device, session, call and command locks remain held
                # until the bounded provider effect and its durable receipt finish.
                if command.action == :voicemail,
                  do: CommsCore.Telephony.Mailboxes.assert_capture_effect_allowed!(call)

                request = request_view(command, call, reconcile)

                # Voicemail protection and other row locks can wait after the
                # first admission check. Current wall-clock authority must
                # still be live at the final effect boundary.
                if DateTime.compare(command.expires_at, now()) != :gt or
                     DateTime.compare(call.expires_at, now()) != :gt or
                     not authorized_call?(call, command),
                   do: Repo.rollback(:telephony_provider_unavailable)

                # Lock waits consume the transaction deadline too. Refuse a
                # fresh provider effect unless its entire bounded lifetime and
                # receipt commit still fit while current authority stays held.
                if deadline - System.monotonic_time(:millisecond) <
                     @provider_effect_budget_ms + @effect_commit_reserve_ms,
                   do: Repo.rollback(:telephony_provider_unavailable)

                ProviderControlPort.execute_control(request)

              other ->
                other
            end

          if outcome in [
               {:error, :telephony_consultation_pending},
               {:error, :telephony_notice_pending}
             ] do
            :snooze
          else
            finish_control!(command, call, outcome)
          end
      end
    end)
  end

  defp finish_control!(command, call, result) do
    attrs =
      case result do
        {:ok, %{control_state: state, pbx_state: bindings}}
        when state in ["connected", "held", "consulting", "transferred", "voicemail"] and
               is_map(bindings) ->
          call |> Call.changeset(%{control_state: state, pbx_state: bindings}) |> Repo.update!()
          %{status: :submitted, completed_at: now()}

        {:ok, :submitted} ->
          %{status: :submitted, completed_at: now()}

        {:error, reason}
        when reason in [
               :telephony_control_unsupported,
               :telephony_destination_forbidden,
               :invalid_telephony_command
             ] ->
          %{status: :failed, completed_at: now(), failure_reason: Atom.to_string(reason)}

        _ ->
          %{status: :unknown, completed_at: now(), failure_reason: "provider_outcome_unknown"}
      end

    update!(command, attrs)

    if command.action in [:complete_transfer, :voicemail] and
         attrs.status in [:submitted, :unknown],
       do: CommsCore.Telephony.CallMonitor.enqueue_bound_call_monitor!(call)

    :complete
  end

  defp worker(id, caller, fun) do
    if RuntimePorts.authorized_job_worker?(:telephony_control, caller) do
      with {:ok, id} <- uuid(id) do
        deadline = System.monotonic_time(:millisecond) + @worker_transaction_budget_ms

        Repo.transaction(
          fn ->
            snapshot = Repo.get(ControlCommand, id)
            if is_nil(snapshot), do: Repo.rollback(:not_found)
            initial_call = Repo.get(Call, snapshot.call_id)
            if is_nil(initial_call), do: Repo.rollback(:not_found)

            if snapshot.action == :voicemail,
              do: CommsCore.Telephony.Mailboxes.lock_capture_effect_policy!(initial_call)

            authorized = authorized_call?(initial_call, snapshot)
            call = Repo.one(from(c in Call, where: c.id == ^snapshot.call_id, lock: "FOR UPDATE"))

            if not authorized and snapshot.status in [:pending, :dispatching] do
              stale = lock_command!(id, call.id)

              update!(stale, %{
                status: :failed,
                completed_at: now(),
                failure_reason: "access_revoked"
              })
            end

            if is_nil(call), do: Repo.rollback(:not_found)
            command = lock_command!(id, call.id)
            fun.(command, call, deadline)
          end,
          timeout: @worker_transaction_budget_ms
        )
      end
    else
      {:error, :forbidden}
    end
  end

  defp system_voicemail?(command, call),
    do:
      command.action == :voicemail and is_nil(command.session_id) and is_nil(command.device_id) and
        call.routing_status == "voicemail" and call.direction == :inbound

  defp authorized_call?(
         call,
         %ControlCommand{action: :voicemail, session_id: nil, device_id: nil} = command
       ) do
    with true <- system_voicemail?(command, call),
         {:ok, %{allow_audio_calls: true}} <- Administration.lock_call_policy(call.tenant_id),
         {:ok, [_]} <-
           Accounts.lock_active_human_directory_users(call.tenant_id, [command.user_id]),
         true <- get_in(ProviderControlPort.capabilities(), [:voicemail, :supported]) == true do
      true
    else
      _ -> false
    end
  end

  defp authorized_call?(call, command) do
    with {:ok, %{allow_audio_calls: true}} <- Administration.lock_call_policy(call.tenant_id),
         {:ok, [_]} <-
           Accounts.lock_active_human_directory_users(call.tenant_id, [command.user_id]),
         :ok <-
           Accounts.lock_push_registration_identity(
             call.tenant_id,
             command.user_id,
             command.device_id
           ),
         {:ok, %AccessGrant{account_type: :human, access_scope: :workspace}} <-
           Accounts.lock_access_grant(%{
             tenant_id: call.tenant_id,
             user_id: command.user_id,
             session_id: command.session_id,
             device_id: command.device_id
           }) do
      call.answer_session_id == command.session_id and call.answer_device_id == command.device_id
    else
      _ -> false
    end
  end

  defp request_view(command, call, reconcile) do
    %ControlRequest{
      command_id: command.id,
      call_id: call.id,
      tenant_id: call.tenant_id,
      action: command.action,
      provider_room: call.provider_room,
      provider_identity: call.provider_identity,
      destination: command.destination,
      pbx_state: call.pbx_state || %{},
      notice_media: CommsCore.Telephony.Mailboxes.notice_for_call(call.id),
      notice_completed_at: command.notice_completed_at,
      expires_at: command.expires_at,
      call_expires_at: call.expires_at,
      system: is_nil(command.session_id),
      reconcile: reconcile
    }
  end

  defp require_state!(call, action) do
    valid =
      case action do
        :hold ->
          call.control_state == "connected"

        :resume ->
          call.control_state == "held"

        :consult_transfer ->
          call.control_state in ["connected", "held"]

        :complete_transfer ->
          call.control_state == "consulting"

        :cancel_transfer ->
          call.control_state == "consulting" or
            (map_size(call.pbx_state || %{}) > 0 and
               Repo.exists?(
                 from(c in ControlCommand,
                   where:
                     c.call_id == ^call.id and c.action == :consult_transfer and
                       c.status == :unknown and not is_nil(c.claimed_at)
                 )
               ))

        :voicemail ->
          call.direction == :inbound and call.control_state in ["connected", "held"]

        :dtmf ->
          call.control_state in ["connected", "consulting"]

        :blind_transfer ->
          call.control_state == "connected"

        _ ->
          false
      end

    if not valid, do: Repo.rollback(:invalid_call_action)
  end

  defp access(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} -> {:ok, grant}
      _ -> {:error, :forbidden}
    end
  end

  defp lock_access!(subject) do
    with {:ok, grant} <- access(subject),
         {:ok, %{allow_audio_calls: true}} <- Administration.lock_call_policy(grant.tenant_id),
         {:ok, [_]} <-
           Accounts.lock_active_human_directory_users(grant.tenant_id, [grant.user_id]),
         {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = current} <-
           Accounts.lock_access_grant(subject) do
      current
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp own_call!(id, grant) do
    case Repo.one(
           from(c in Call,
             where:
               c.id == ^id and c.tenant_id == ^grant.tenant_id and c.user_id == ^grant.user_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Call{} = call -> call
      _ -> Repo.rollback(:not_found)
    end
  end

  defp require_owner!(call, grant) do
    if is_nil(call.answer_session_id) or call.answer_session_id != grant.session_id or
         call.answer_device_id != grant.device_id,
       do: Repo.rollback(:answered_elsewhere)
  end

  defp lock_command!(id, call_id) do
    case Repo.one(
           from(c in ControlCommand,
             where: c.id == ^id and c.call_id == ^call_id,
             lock: "FOR UPDATE"
           )
         ) do
      %ControlCommand{} = command -> command
      _ -> Repo.rollback(:not_found)
    end
  end

  defp update!(%ControlCommand{} = command, attrs) do
    saved = command |> ControlCommand.changeset(attrs) |> Repo.update!()
    publish!(saved)
    saved
  end

  defp view(command, dispatch \\ false) do
    expired =
      command.status == :dispatching and DateTime.compare(command.expires_at, now()) != :gt

    %ControlView{
      id: command.id,
      call_id: command.call_id,
      action: command.action,
      status: if(expired, do: :unknown, else: command.status),
      dispatch: dispatch and not expired,
      created_at: command.inserted_at,
      expires_at: command.expires_at,
      completed_at: command.completed_at,
      failure_reason: if(expired, do: "submission_deadline", else: command.failure_reason)
    }
  end

  defp publish!(command) do
    Outbox.insert_and_enqueue!(%{
      tenant_id: command.tenant_id,
      event_type: "telephony.control.updated",
      aggregate_type: "telephony_control",
      aggregate_id: command.id,
      payload: %{
        call_id: command.call_id,
        user_id: command.user_id,
        action: Atom.to_string(command.action),
        status: Atom.to_string(command.status)
      },
      available_at: now()
    })
  end

  defp enqueue!(id) do
    %{"command_id" => id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:telephony_control),
      queue: :telephony,
      max_attempts: 20
    )
    |> Oban.insert!()
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp action(value) when is_atom(value), do: action(Atom.to_string(value))

  defp action(value) do
    case Map.fetch(@actions, value) do
      {:ok, action} -> {:ok, action}
      _ -> {:error, :invalid_call_action}
    end
  end

  defp payload(:dtmf, attrs) do
    digit = value(attrs, :digit)

    if is_binary(digit) and Regex.match?(~r/^[0-9*#ABCD]$/, digit),
      do: {:ok, digit},
      else: {:error, :invalid_telephony_command}
  end

  defp payload(action, attrs) when action in [:blind_transfer, :consult_transfer] do
    destination = value(attrs, :destination)

    if is_binary(destination) and Regex.match?(~r/^\+[1-9][0-9]{7,14}$/, destination),
      do: {:ok, destination},
      else: {:error, :invalid_telephony_command}
  end

  defp payload(_, _), do: {:ok, ""}

  defp key(value) when is_binary(value) and byte_size(value) in 1..128 do
    if String.trim(value) != "", do: {:ok, value}, else: {:error, :idempotency_key_required}
  end

  defp key(_), do: {:error, :idempotency_key_required}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now()
end
