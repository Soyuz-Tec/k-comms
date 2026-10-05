defmodule CommsCore.Telephony.Ivr do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.{
    Accounts,
    Administration,
    AdmissionQuotas,
    Audit,
    Repo,
    RuntimePorts,
    ValidationError
  }

  alias CommsCore.Accounts.{AccessGrant, DirectoryUsersLockQuery}

  alias CommsCore.Telephony.{
    Call,
    IvrEffectClaim,
    IvrEvent,
    IvrEventReceipt,
    IvrMenu,
    IvrProviderPort,
    IvrProviderRequest,
    IvrRun,
    IvrStateMachine,
    Mailbox,
    Mailboxes,
    Number,
    ProviderControlPort,
    Route,
    CallMonitor,
    ControlCommand,
    Routing,
    Voicemail,
    VoicemailProviderPort,
    VoicemailStoragePort
  }

  @active_phases [
    :pending,
    :preparing,
    :playing,
    :awaiting_digit,
    :selected,
    :routing,
    :destination_pending,
    :destination_connecting,
    :unknown
  ]
  @lock_budget_ms 15_000
  @provider_budget_ms 10_000
  @max_callers 100

  def config(subject) do
    admin_transaction(
      subject,
      fn grant, deadline ->
        menu = Repo.get_by(IvrMenu, tenant_id: grant.tenant_id)

        result = %{
          menu: view(menu),
          available: IvrProviderPort.ready?(),
          max_active_callers: @max_callers,
          approved_prompts: Application.get_env(:comms_core, :telephony_ivr_prompt_allowlist, [])
        }

        fresh_admin!(subject, grant, deadline, false)
        result
      end,
      false
    )
  end

  def save(attrs, subject) when is_map(attrs) do
    with true <- valid_fields?(attrs),
         version when is_integer(version) and version >= 0 <- value(attrs, :version),
         reason when is_binary(reason) and byte_size(reason) in 3..500 <- value(attrs, :reason) do
      admin_transaction(subject, fn grant, deadline ->
        number =
          Repo.one(from(n in Number, where: n.tenant_id == ^grant.tenant_id, lock: "FOR SHARE"))

        if is_nil(number), do: Repo.rollback(:telephony_not_configured)

        current =
          Repo.one(from(m in IvrMenu, where: m.tenant_id == ^grant.tenant_id, lock: "FOR UPDATE"))

        if version != if(current, do: current.version, else: 0), do: Repo.rollback(:stale_version)

        parameters =
          Map.new(
            [
              :name,
              :prompt_media,
              :choices,
              :fallback,
              :digit_timeout_seconds,
              :max_retries,
              :enabled
            ],
            &{&1, value(attrs, &1)}
          )
          |> Map.merge(%{tenant_id: grant.tenant_id, number_id: number.id, version: version + 1})

        changeset = IvrMenu.changeset(current || %IvrMenu{}, parameters)

        if not changeset.valid? do
          {:ok, error} = ValidationError.from(changeset)
          Repo.rollback(error)
        end

        if parameters.enabled do
          if not IvrProviderPort.ready?(), do: Repo.rollback(:telephony_ivr_unavailable)

          if not approved_prompt?(parameters.prompt_media),
            do: Repo.rollback(:telephony_ivr_prompt_unapproved)

          Enum.each(
            Map.values(parameters.choices) ++ [parameters.fallback],
            &require_target!(&1, number)
          )
        end

        menu = Repo.insert_or_update!(changeset)
        audit!(grant, menu, reason)
        fresh_admin!(subject, grant, deadline)
        view(menu)
      end)
    else
      _ -> {:error, :invalid_telephony_ivr}
    end
  end

  def save(_, _), do: {:error, :invalid_telephony_ivr}

  @doc false
  def admission(number) do
    # The caller's transaction must take the existing shared tenant admission
    # lock before policy/identity/assignment resources. This serializes the hard
    # per-number caller count against all IVR admissions.
    if not Repo.in_transaction?(), do: raise("IVR admission requires the call owner transaction")

    menu =
      Repo.one(
        from(m in IvrMenu, where: m.number_id == ^number.id and m.enabled, lock: "FOR SHARE")
      )

    case menu do
      nil ->
        :none

      menu ->
        active =
          Repo.aggregate(
            from(r in IvrRun,
              where: r.tenant_id == ^number.tenant_id and r.phase in ^@active_phases
            ),
            :count
          )

        owner_active? =
          match?(
            {:ok, [_]},
            Accounts.lock_active_human_directory_users(number.tenant_id, [number.user_id])
          )

        if active >= @max_callers or not owner_active? or not IvrProviderPort.ready?() or
             not approved_prompt?(menu.prompt_media) do
          {:error, :telephony_ivr_unavailable}
        else
          {:ok, menu}
        end
    end
  end

  @doc false
  def reserve!(%Call{status: :ringing, routing_status: "ivr"} = call, %IvrMenu{} = menu) do
    if not Repo.in_transaction?(),
      do: raise("IVR reservation requires the call owner transaction")

    snapshot =
      Map.take(view(menu), [
        :prompt_media,
        :choices,
        :fallback,
        :digit_timeout_seconds,
        :max_retries
      ])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    run =
      %IvrRun{}
      |> IvrRun.changeset(%{
        tenant_id: call.tenant_id,
        call_id: call.id,
        menu_id: menu.id,
        menu_version: menu.version,
        snapshot: snapshot,
        expires_at: call.expires_at
      })
      |> Repo.insert!()

    enqueue!(run.id)
    run
  end

  def handle_webhook(body, authorization) do
    with {:ok, %IvrEvent{} = event} <- IvrProviderPort.verify_event(body, authorization) do
      event_transaction(event)
    end
  end

  def advance(id, caller) do
    if RuntimePorts.authorized_job_worker?(:telephony_ivr, caller) do
      with {:ok, id} <- Ecto.UUID.cast(id) do
        run_transaction(id, fn call, run, deadline -> advance_locked(call, run, deadline) end)
      else
        _ -> {:error, :not_found}
      end
    else
      {:error, :forbidden}
    end
  end

  def execute_claim(%IvrEffectClaim{action: action} = claim, caller)
      when action in [:play, :destination, :connect_destination] do
    if RuntimePorts.authorized_job_worker?(:telephony_ivr, caller) do
      # Commit consumption before any forward effect. A retry cannot recover
      # the nonce from a job or database row and consumption cannot roll back
      # with a late network outcome.
      with {:ok, :consumed} <-
             run_transaction(claim.run_id, fn _call, run, _deadline ->
               if not matching_claim?(run, claim) or not is_nil(run.effect_started_at),
                 do: Repo.rollback(:telephony_ivr_claim_consumed)

               update!(run, %{effect_started_at: now()})
               :consumed
             end) do
        run_transaction(claim.run_id, fn call, run, deadline ->
          if not matching_claim?(run, claim) or is_nil(run.effect_started_at),
            do: Repo.rollback(:telephony_ivr_claim_consumed)

          effect_budget!(deadline)

          result =
            case claim.action do
              :play ->
                IvrProviderPort.play(request(call, run, deadline, false))

              :destination ->
                IvrProviderPort.destination(%{
                  request(call, run, deadline, false)
                  | destination: run.selected_target["destination"]
                })

              :connect_destination ->
                IvrProviderPort.destination(%{
                  request(call, run, deadline, false)
                  | destination: run.selected_target["destination"],
                    stage: :connect
                })
            end

          finish_effect!(
            call,
            run,
            if(claim.action == :connect_destination, do: :destination, else: claim.action),
            result
          )
        end)
      end
    else
      {:error, :forbidden}
    end
  end

  def execute_claim(_, _), do: {:error, :forbidden}

  @doc false
  def original_deadline(call_id) do
    Repo.one(from(r in IvrRun, where: r.call_id == ^call_id, select: r.expires_at))
  end

  @doc false
  def cancel_calls!(call_ids) when is_list(call_ids) do
    if not Repo.in_transaction?(),
      do: raise("IVR cancellation requires the call owner transaction")

    Repo.update_all(
      from(r in IvrRun, where: r.call_id in ^call_ids and r.phase in ^@active_phases),
      set: [phase: :cancelled, completed_at: now(), updated_at: now()]
    )

    :ok
  end

  def rollback_hazard_count do
    Repo.aggregate(IvrMenu, :count) + Repo.aggregate(IvrRun, :count) +
      Repo.aggregate(IvrEventReceipt, :count) +
      Repo.aggregate(
        from(c in Call, where: c.routing_status in ["ivr", "ivr_destination"]),
        :count
      )
  end

  defp event_transaction(event) do
    run_transaction(event.run_id, fn call, run, _deadline ->
      if not exact_event?(event, call, run), do: Repo.rollback(:invalid_provider_event)
      existing = Repo.get_by(IvrEventReceipt, event_id: event.event_id)

      if existing do
        if existing.run_id != run.id or existing.body_fingerprint != event.body_fingerprint,
          do: Repo.rollback(:event_conflict)

        :duplicate
      else
        # Invalid/stale steps cannot consume the receipt budget and deny the
        # next valid prompt. Bound authentic current-step caller events as well.
        if event.step != run.step or IvrStateMachine.terminal?(run.phase) do
          :ignored
        else
          if Repo.aggregate(from(e in IvrEventReceipt, where: e.run_id == ^run.id), :count) >= 32 and
               event.type != :disconnected,
             do: Repo.rollback(:telephony_ivr_event_capacity)

          %IvrEventReceipt{}
          |> IvrEventReceipt.changeset(%{
            tenant_id: call.tenant_id,
            run_id: run.id,
            event_id: event.event_id,
            body_fingerprint: event.body_fingerprint,
            step: event.step,
            event_type: event_type(event.type)
          })
          |> Repo.insert!()

          if event.type == :disconnected do
            fail_call!(call, run, "ivr_caller_disconnected")
          else
            {result, changes} = IvrStateMachine.transition(run, event, now())

            if changes != %{} do
              update!(run, changes)
              enqueue!(run.id)
            end

            result
          end
        end
      end
    end)
  end

  defp run_transaction(id, operation) do
    with {:ok, id} <- Ecto.UUID.cast(id), %IvrRun{} = snapshot <- Repo.get(IvrRun, id) do
      deadline = System.monotonic_time(:millisecond) + @lock_budget_ms

      Repo.transaction(
        fn ->
          budget!(deadline)

          if get_in(snapshot.selected_target || %{}, ["kind"]) == "voicemail" do
            initial_call = Repo.get(Call, snapshot.call_id)
            if is_nil(initial_call), do: Repo.rollback(:not_found)
            # Governed media admission is always the first policy lock. It must
            # precede quota, identity, Call, mailbox and pending capture state.
            Mailboxes.lock_capture_effect_policy!(initial_call)
            budget!(deadline)
          end

          :ok = AdmissionQuotas.lock_tenant(snapshot.tenant_id)

          policy =
            case Administration.lock_call_policy(snapshot.tenant_id) do
              {:ok, policy} -> policy
              _ -> Repo.rollback(:forbidden)
            end

          target_available = lock_route_parents!(snapshot, deadline)

          call =
            Repo.one(
              from(c in Call,
                where: c.id == ^snapshot.call_id and c.tenant_id == ^snapshot.tenant_id,
                lock: "FOR UPDATE"
              )
            )

          run =
            Repo.one(
              from(r in IvrRun,
                where: r.id == ^id and r.tenant_id == ^snapshot.tenant_id,
                lock: "FOR UPDATE"
              )
            )

          if is_nil(call) or is_nil(run), do: Repo.rollback(:not_found)

          if snapshot.selected_target != run.selected_target,
            do: Repo.rollback(:telephony_ivr_retry)

          budget!(deadline)

          cond do
            IvrStateMachine.terminal?(run.phase) ->
              :complete

            call.status not in [:ringing, :answered] ->
              update!(run, %{phase: :cancelled, completed_at: now()})
              :complete

            not target_available ->
              fail_call!(call, run, "ivr_target_unavailable")

            not policy.allow_audio_calls ->
              fail_call!(call, run, "audio_calls_disabled")

            DateTime.compare(call.expires_at, now()) != :gt ->
              fail_call!(call, run, "ivr_deadline")

            true ->
              result = operation.(call, run, deadline)
              budget!(deadline)
              # Network acceptance never extends the original caller authority.
              # A response arriving at the deadline must commit termination and
              # cleanup, including any uncertain once-consumed provider effect.
              if DateTime.compare(call.expires_at, now()) != :gt do
                current_call = Repo.get!(Call, call.id)

                if current_call.status in [:ringing, :answered],
                  do: fail_call!(current_call, Repo.get!(IvrRun, run.id), "ivr_deadline"),
                  else: result
              else
                result
              end
          end
        end,
        timeout: 20_000
      )
    else
      _ -> {:error, :not_found}
    end
  end

  defp advance_locked(call, run, deadline) do
    case IvrStateMachine.timeout(run, now()) do
      {:applied, changes} ->
        run = update!(run, changes)

        if run.phase == :failed,
          do: fail_call!(call, run, "ivr_deadline"),
          else: advance_phase(call, run, deadline)

      _ ->
        advance_phase(call, run, deadline)
    end
  end

  defp advance_phase(_call, %IvrRun{phase: :awaiting_digit}, _deadline), do: {:wait, 1}

  defp advance_phase(call, %IvrRun{phase: :selected} = run, deadline),
    do: select_target!(call, run, deadline)

  defp advance_phase(_call, %IvrRun{phase: :pending} = run, _deadline) do
    # First persist a claim in this transaction. A separate worker invocation
    # prepares and stores exact handles before any playback/origination.
    update!(run, %{phase: :preparing, claimed_at: now()})
    {:wait, 1}
  end

  defp advance_phase(call, %IvrRun{phase: :preparing} = run, deadline) do
    effect_budget!(deadline)
    request = request(call, run, deadline, false)

    case IvrProviderPort.prepare(request) do
      {:ok, bindings} ->
        if not valid_bindings?(bindings, call), do: Repo.rollback(:telephony_pbx_binding_invalid)
        update!(run, %{bindings: bindings, phase: :playing})
        call |> Call.changeset(%{pbx_state: bindings}) |> Repo.update!()
        {:wait, 1}

      _ ->
        {:wait, 2}
    end
  end

  defp advance_phase(_call, %IvrRun{phase: :playing} = run, _deadline), do: claim!(run, :play)

  defp advance_phase(call, %IvrRun{phase: :unknown} = run, deadline) do
    effect_budget!(deadline)
    # The frozen claim is durable before this invocation. Following an uncertain
    # effect only exact read-only playback reconciliation is permitted.
    result = IvrProviderPort.play(request(call, run, deadline, true))
    finish_observation!(call, run, :play, result)
  end

  defp advance_phase(call, %IvrRun{phase: :destination_pending} = run, deadline) do
    effect_budget!(deadline)

    result =
      IvrProviderPort.destination(%{
        request(call, run, deadline, true)
        | destination: run.selected_target["destination"]
      })

    finish_observation!(call, run, :destination, result)
  end

  defp advance_phase(call, %IvrRun{phase: :destination_connecting} = run, deadline) do
    effect_budget!(deadline)

    result =
      IvrProviderPort.destination(%{
        request(call, run, deadline, true)
        | destination: run.selected_target["destination"],
          stage: :connect
      })

    finish_observation!(call, run, :destination, result)
  end

  defp advance_phase(_call, %IvrRun{phase: :routing}, _deadline), do: {:wait, 1}
  defp advance_phase(_call, _run, _deadline), do: :complete

  defp claim!(run, action) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    phase = claim_phase(action)

    update!(run, %{
      phase: phase,
      effect_claim_fingerprint: fingerprint(nonce),
      effect_started_at: nil,
      failure_reason: Atom.to_string(action) <> "_claimed"
    })

    {:effect, %IvrEffectClaim{run_id: run.id, step: run.step, action: action, nonce: nonce}}
  end

  defp matching_claim?(run, claim) do
    expected_phase = claim_phase(claim.action)

    run.phase == expected_phase and run.step == claim.step and
      run.failure_reason == Atom.to_string(claim.action) <> "_claimed" and
      is_binary(claim.nonce) and byte_size(claim.nonce) == 64 and
      run.effect_claim_fingerprint == fingerprint(claim.nonce)
  end

  defp finish_observation!(call, run, action, result) do
    if action == :destination and result in [{:ok, :ready}, {:ok, :connected}] do
      finish_effect!(call, run, action, result)
    else
      # A reader may win the Call lock between durable claim consumption and
      # the consuming worker's forward transaction. An inconclusive read must
      # not invalidate that worker's original claim or mint a replacement.
      if is_binary(run.failure_reason) and String.ends_with?(run.failure_reason, "_claimed"),
        do: {:wait, 1},
        else: finish_effect!(call, run, action, result)
    end
  end

  defp finish_effect!(_call, run, :play, result) do
    reason =
      if result == {:ok, :pending}, do: "playback_submitted", else: "playback_outcome_unknown"

    update!(run, %{phase: :unknown, failure_reason: reason})
    {:wait, 1}
  end

  defp finish_effect!(_call, run, :destination, {:ok, :ready}),
    do: claim!(run, :connect_destination)

  defp finish_effect!(call, run, :destination, {:ok, :connected}) do
    if ProviderControlPort.authorize_destination(run.selected_target["destination"]) != :ok,
      do: Repo.rollback(:telephony_transfer_destination_forbidden)

    saved =
      call
      |> Call.changeset(%{
        control_state: "transferred",
        status: :answered,
        answered_at: now(),
        routing_status: "ivr_destination",
        offered_user_ids: [],
        pbx_state: Map.put(run.bindings, "mixing", run.bindings["destination_bridge"])
      })
      |> Repo.update!()

    update!(run, %{phase: :completed, completed_at: now(), failure_reason: nil})
    CallMonitor.enqueue_bound_call_monitor!(saved)
    publish!(saved)
    :complete
  end

  defp finish_effect!(_call, run, :destination, _result) do
    update!(run, %{phase: run.phase, failure_reason: "destination_outcome_unknown"})
    {:wait, 1}
  end

  defp select_target!(call, run, _deadline) do
    number = Repo.get_by!(Number, id: call.number_id, tenant_id: call.tenant_id)
    require_target!(run.selected_target, number)

    case run.selected_target do
      %{"kind" => "hangup"} ->
        fail_call!(call, run, "ivr_hangup")

      %{"kind" => "route"} ->
        routing = Routing.admission(number)

        if not routing.eligible or routing.route_id != run.selected_target["route_id"],
          do: Repo.rollback(:telephony_ivr_target_unavailable)

        saved =
          call
          |> Call.changeset(%{
            user_id: routing.user_id,
            route_id: routing.route_id,
            routing_status: routing.routing_status,
            offered_user_ids: routing.offered_user_ids,
            route_expires_at: earliest(routing.route_expires_at, call.expires_at)
          })
          |> Repo.update!()

        update!(run, %{phase: :completed, completed_at: now()})
        Routing.enqueue_waiting(saved)
        publish!(saved)
        :complete

      %{"kind" => "voicemail", "mailbox_id" => mailbox_id} ->
        capture!(call, run, mailbox_id)

      %{"kind" => "destination"} ->
        # The existing handoff monitor requires an established consultation
        # leg. Keep IVR pending until exact connection proof, otherwise a
        # caller-only prompt would look like an already ended transfer.
        claim!(run, :destination)
    end
  end

  defp capture!(call, run, mailbox_id) do
    box =
      Repo.get_by(Mailbox,
        id: mailbox_id,
        tenant_id: call.tenant_id,
        number_id: call.number_id,
        enabled: true
      )

    if is_nil(box), do: Repo.rollback(:telephony_ivr_target_unavailable)
    notice = Mailboxes.reserve!(call)
    message = Repo.get_by!(Voicemail, tenant_id: call.tenant_id, call_id: call.id)
    capture_deadline = earliest(message.recording_deadline, call.expires_at)
    message |> Voicemail.changeset(%{recording_deadline: capture_deadline}) |> Repo.update!()

    saved =
      call
      |> Call.changeset(%{
        routing_status: "voicemail",
        control_state: "voicemail",
        user_id: box.user_id,
        offered_user_ids: [],
        expires_at: capture_deadline
      })
      |> Repo.update!()

    command =
      %ControlCommand{}
      |> ControlCommand.changeset(%{
        tenant_id: call.tenant_id,
        call_id: call.id,
        user_id: box.user_id,
        action: :voicemail,
        status: :pending,
        idempotency_key: "ivr-voicemail:" <> run.id,
        payload_hash: fingerprint(notice),
        expires_at: earliest(DateTime.add(now(), 60, :second), call.expires_at)
      })
      |> Repo.insert!()

    %{"command_id" => command.id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:telephony_control),
      queue: :telephony,
      max_attempts: 20
    )
    |> Repo.insert!()

    update!(run, %{phase: :completed, completed_at: now()})
    publish!(saved)
    :complete
  end

  defp lock_route_parents!(run, deadline) do
    call = Repo.get(Call, run.call_id)
    if is_nil(call), do: Repo.rollback(:not_found)
    number = Repo.get_by(Number, id: call.number_id, tenant_id: run.tenant_id)
    if is_nil(number), do: Repo.rollback(:telephony_not_configured)
    target = run.selected_target || %{}

    route =
      if target["kind"] == "route",
        do: Repo.get_by(Route, id: target["route_id"], tenant_id: run.tenant_id),
        else: nil

    box =
      if target["kind"] == "voicemail",
        do: Repo.get_by(Mailbox, id: target["mailbox_id"], tenant_id: run.tenant_id),
        else: nil

    ids =
      [call.user_id, number.user_id] ++
        if(route, do: route.member_ids, else: []) ++ if(box, do: [box.user_id], else: [])

    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    available =
      case Accounts.lock_active_directory_users(%DirectoryUsersLockQuery{
             tenant_id: run.tenant_id,
             user_ids: ids,
             deadline: deadline
           }) do
        {:ok, users} when length(users) == length(ids) ->
          Enum.all?(users, &(&1.account_type == :human))

        _ ->
          false
      end

    # Configuration can change between the initial projection and row lock.
    # Refuse that snapshot rather than acquiring new Users after Route/Call.
    if available and route do
      locked = Repo.one(from(r in Route, where: r.id == ^route.id, lock: "FOR UPDATE"))

      if is_nil(locked) or locked.version != route.version or
           locked.member_ids != route.member_ids,
         do: Repo.rollback(:telephony_ivr_retry)
    end

    if available and box do
      locked = Repo.one(from(b in Mailbox, where: b.id == ^box.id, lock: "FOR UPDATE"))

      if is_nil(locked) or locked.version != box.version or locked.user_id != box.user_id,
        do: Repo.rollback(:telephony_ivr_retry)
    end

    available
  end

  defp fail_call!(call, run, reason) do
    timestamp = now()
    status = if is_nil(call.answered_at), do: :no_answer, else: :ended

    saved =
      call
      |> Call.changeset(%{status: status, ended_at: timestamp, end_reason: reason})
      |> Repo.update!()

    update!(run, %{
      phase: if(reason == "ivr_hangup", do: :completed, else: :failed),
      completed_at: timestamp,
      failure_reason: reason
    })

    %{"call_id" => call.id}
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:telephony_cleanup),
      queue: :lifecycle,
      max_attempts: 100
    )
    |> Repo.insert!()

    publish!(saved)
    :complete
  end

  defp publish!(call),
    do:
      CommsCore.Outbox.insert_and_enqueue!(%{
        tenant_id: call.tenant_id,
        event_type: "telephony.call.updated",
        aggregate_type: "telephony_call",
        aggregate_id: call.id,
        payload: %{call_id: call.id, user_id: call.user_id, status: Atom.to_string(call.status)},
        available_at: now()
      })

  defp request(call, run, deadline, reconcile) do
    %IvrProviderRequest{
      run_id: run.id,
      call_id: call.id,
      tenant_id: call.tenant_id,
      provider_room: call.provider_room,
      provider_identity: call.provider_identity,
      step: run.step,
      playback_id: IvrStateMachine.playback_id(run.id, run.step),
      prompt_media: run.snapshot["prompt_media"],
      bindings: run.bindings,
      expires_at: call.expires_at,
      effect_deadline_ms:
        min(
          deadline - 2_000,
          System.monotonic_time(:millisecond) +
            max(0, DateTime.diff(call.expires_at, now(), :millisecond))
        ),
      reconcile: reconcile
    }
  end

  defp exact_event?(event, call, run) do
    event.run_id == run.id and event.channel_id == run.bindings["external"] and
      DateTime.compare(event.occurred_at, run.inserted_at) != :lt and
      DateTime.compare(event.occurred_at, DateTime.add(now(), 5, :second)) != :gt and
      (event.type == :playback_finished or
         (event.type in [:digit, :disconnected] and event.tenant_id == call.tenant_id and
            event.call_id == call.id and
            event.provider_room == call.provider_room and
            event.provider_identity == call.provider_identity))
  end

  defp require_target!(%{"kind" => "hangup"}, _number), do: :ok

  defp require_target!(%{"kind" => "route", "route_id" => id}, number) do
    case Repo.get_by(Route,
           id: id,
           tenant_id: number.tenant_id,
           number_id: number.id,
           enabled: true
         ) do
      %Route{mode: mode} ->
        capability = if mode == :queue, do: :queues, else: :shared_lines

        if get_in(ProviderControlPort.capabilities(), [capability, :supported]) != true,
          do: Repo.rollback(:telephony_control_unsupported)

      _ ->
        Repo.rollback(:telephony_ivr_target_unavailable)
    end
  end

  defp require_target!(%{"kind" => "voicemail", "mailbox_id" => id}, number) do
    if is_nil(
         Repo.get_by(Mailbox,
           id: id,
           tenant_id: number.tenant_id,
           number_id: number.id,
           enabled: true
         )
       ) or
         not VoicemailProviderPort.ready?() or not VoicemailStoragePort.ready?(),
       do: Repo.rollback(:telephony_ivr_target_unavailable)
  end

  defp require_target!(%{"kind" => "destination", "destination" => destination}, _number) do
    if ProviderControlPort.authorize_destination(destination) != :ok,
      do: Repo.rollback(:telephony_transfer_destination_forbidden)
  end

  defp admin_transaction(subject, operation, step_up? \\ true) do
    with {:ok, %AccessGrant{account_type: :human, access_scope: :workspace}} <-
           Accounts.access_grant(subject) do
      deadline = System.monotonic_time(:millisecond) + @lock_budget_ms

      Repo.transaction(
        fn ->
          case Accounts.lock_content_write_grant(subject, deadline) do
            {:ok, %AccessGrant{account_type: :human, access_scope: :workspace} = grant} ->
              fresh_admin!(subject, grant, deadline, step_up?)
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

  defp fresh_admin!(subject, original, deadline, step_up? \\ true) do
    budget!(deadline)

    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace, role: role} = current}
      when role in [:owner, :admin] and current.tenant_id == original.tenant_id and
             current.user_id == original.user_id ->
        if step_up? and not current.step_up_recent?, do: Repo.rollback(:step_up_required)

      _ ->
        Repo.rollback(:forbidden)
    end
  end

  defp valid_bindings?(bindings, call) when is_map(bindings) do
    exact = "kc_hold_" <> String.replace(call.id, "-", "")
    external = bindings["external"]

    is_binary(external) and Regex.match?(~r/^[A-Za-z0-9_.:-]{1,200}$/, external) and
      bindings["holding"] == exact and
      (bindings["mixing"] == exact or
         (is_binary(bindings["mixing"]) and
            Regex.match?(~r/^[A-Za-z0-9_.:-]{1,200}$/, bindings["mixing"]))) and
      bindings["consult"] == "kc_consult_" <> String.replace(call.id, "-", "") and
      (is_nil(bindings["app"]) or
         (is_binary(bindings["app"]) and
            Regex.match?(~r/^[A-Za-z0-9_.:-]{1,200}$/, bindings["app"]))) and
      map_size(bindings) == 7 and
      bindings["destination_bridge"] == "kc_ivr_mix_" <> String.replace(call.id, "-", "") and
      bindings["recording"] == "kc_vm_" <> String.replace(call.id, "-", "")
  end

  defp valid_bindings?(_, _), do: false

  defp approved_prompt?(prompt),
    do: prompt in Application.get_env(:comms_core, :telephony_ivr_prompt_allowlist, [])

  defp audit!(grant, menu, reason) do
    case Audit.record(%{
           tenant_id: grant.tenant_id,
           actor_user_id: grant.user_id,
           action: "telephony.ivr.saved",
           resource_type: "telephony_ivr_menu",
           resource_id: menu.id,
           metadata: %{reason: reason, version: menu.version, enabled: menu.enabled}
         }) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_failed)
    end
  end

  defp valid_fields?(attrs),
    do:
      MapSet.new(Enum.map(Map.keys(attrs), &to_string/1)) ==
        MapSet.new(
          ~w(name prompt_media choices fallback digit_timeout_seconds max_retries enabled version reason)
        )

  defp view(nil), do: nil

  defp view(menu),
    do:
      Map.take(menu, [
        :id,
        :name,
        :prompt_media,
        :choices,
        :fallback,
        :digit_timeout_seconds,
        :max_retries,
        :enabled,
        :version
      ])

  defp update!(run, changes), do: run |> IvrRun.changeset(changes) |> Repo.update!()

  defp enqueue!(run_id),
    do:
      %{"run_id" => run_id}
      |> Oban.Job.new(
        worker: RuntimePorts.job_worker_name!(:telephony_ivr),
        queue: :lifecycle,
        max_attempts: 100
      )
      |> Oban.insert!()

  defp effect_budget!(deadline) do
    budget!(deadline)

    if deadline - System.monotonic_time(:millisecond) < @provider_budget_ms + 2_000,
      do: Repo.rollback(:telephony_ivr_unavailable)
  end

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:forbidden)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:forbidden)
    :ok
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp earliest(left, right), do: if(DateTime.compare(left, right) == :gt, do: right, else: left)
  defp claim_phase(:play), do: :unknown
  defp claim_phase(:destination), do: :destination_pending
  defp claim_phase(:connect_destination), do: :destination_connecting
  defp event_type(:digit), do: "ChannelDtmfReceived"
  defp event_type(:playback_finished), do: "PlaybackFinished"
  defp event_type(:disconnected), do: "ChannelDestroyed"
end
