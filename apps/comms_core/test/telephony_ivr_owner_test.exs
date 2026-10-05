defmodule CommsCore.TelephonyIvrOwnerTest.Provider do
  @behaviour CommsCore.Telephony.IvrProviderPort.Contract
  def ready?, do: Application.get_env(:comms_core, :ivr_test_ready, true)

  def prepare(request) do
    compact = String.replace(request.call_id, "-", "")

    {:ok,
     %{
       "external" => "external-" <> compact,
       "app" => nil,
       "mixing" => "kc_hold_" <> compact,
       "holding" => "kc_hold_" <> compact,
       "consult" => "kc_consult_" <> compact,
       "recording" => "kc_vm_" <> compact,
       "destination_bridge" => "kc_ivr_mix_" <> compact
     }}
  end

  def play(%{reconcile: true}), do: {:ok, :pending}

  def play(request) do
    send(self(), {:ivr_play, request})
    {:ok, :pending}
  end

  def destination(request) do
    send(self(), {:ivr_destination, request})
    {:error, :telephony_outcome_unknown}
  end

  def verify_event(body, authorization),
    do: CommsIntegrations.Telephony.IvrARI.verify_event(body, authorization)
end

defmodule CommsCore.TelephonyIvrOwnerTest.ControlProvider do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract
  def capabilities, do: %{queues: %{supported: true}, shared_lines: %{supported: true}}
  def authorize_destination(_), do: {:error, :telephony_destination_forbidden}
  def execute_control(_), do: {:error, :telephony_control_unsupported}
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}
  def cleanup_call(_), do: {:error, :telephony_provider_unavailable}
  def bound_call_status(_), do: {:error, :telephony_provider_unavailable}
end

defmodule CommsCore.TelephonyIvrOwnerTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.Telephony
  alias CommsCore.Telephony.{AgentState, Call, IvrRun}
  alias CommsIntegrations.Telephony.LiveKit
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.{TelephonyExpiryWorker, TelephonyIvrWorker}
  @secret String.duplicate("s", 32)

  setup do
    bindings = [
      {:comms_core, :telephony_ivr_adapter, CommsCore.TelephonyIvrOwnerTest.Provider},
      {:comms_core, :telephony_ivr_prompt_allowlist, ["sound:custom/menu"]},
      {:comms_core, :telephony_control_adapter, CommsCore.TelephonyIvrOwnerTest.ControlProvider},
      {:comms_integrations, :telephony_ivr_prompt_allowlist, ["sound:custom/menu"]},
      {:comms_integrations, :telephony_pbx_webhook_secret, @secret},
      {:comms_core, :ivr_test_ready, true}
    ]

    previous =
      Enum.map(bindings, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    Enum.each(bindings, fn {app, key, value} -> Application.put_env(app, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  test "retained completed IVR and expired agent rows remain owner rollback hazards" do
    {account, subject} = ready()
    {call, run, _claim} = prepare(subject)
    assert Telephony.rollback_ivr_hazard_count() == 3

    Repo.get!(Call, call.id)
    |> Ecto.Changeset.change(
      status: :ended,
      routing_status: "individual",
      ended_at: DateTime.utc_now()
    )
    |> Repo.update!()

    Repo.get!(IvrRun, run.id)
    |> Ecto.Changeset.change(phase: :completed, completed_at: DateTime.utc_now())
    |> Repo.update!()

    assert Telephony.rollback_ivr_hazard_count() == 2

    assert {:ok, %{version: 2, enabled: false}} =
             Telephony.save_ivr(%{menu() | enabled: false, version: 1}, subject)

    assert Telephony.rollback_ivr_hazard_count() == 2

    assert {:ok, _} =
             Telephony.save_route(
               %{
                 name: "Retained queue",
                 mode: "queue",
                 policy: "round_robin",
                 member_ids: [account.user.id],
                 max_waiting: 10,
                 max_wait_seconds: 120,
                 enabled: true,
                 reason: "Synthetic retained eligibility"
               },
               subject
             )

    assert {:ok, _} =
             Telephony.set_agent_queue_state(
               %{state: "away", duration_seconds: 60, version: 0},
               subject
             )

    past = DateTime.utc_now() |> DateTime.add(-120, :second)

    Repo.update_all(from(s in AgentState, where: s.tenant_id == ^call.tenant_id),
      set: [updated_at: DateTime.add(past, -60, :second), expires_at: past]
    )

    assert {:ok, %{state: :ready, explicit: false}} = Telephony.agent_queue_state(subject)
    assert Telephony.rollback_agent_state_hazard_count() == 1

    fragment = Telephony.release_tenant_fingerprint_fragment(Repo, call.tenant_id)
    assert fragment.telephony_calls == [call.id]
    assert fragment.telephony_ivr_runs == [run.id]
    assert length(fragment.telephony_agent_states) == 1
    other = Fixtures.account_fixture()

    assert Telephony.release_tenant_fingerprint_fragment(Repo, other.tenant.id) == %{
             telephony_calls: [],
             telephony_ivr_menus: [],
             telephony_ivr_runs: [],
             telephony_ivr_event_receipts: [],
             telephony_agent_states: []
           }
  end

  test "enabled menus require qualified provider while disabled policy remains editable" do
    {_account, subject} = ready()
    Application.put_env(:comms_core, :ivr_test_ready, false)
    assert {:ok, %{available: false}} = Telephony.ivr_config(subject)
    assert {:error, :telephony_ivr_unavailable} = Telephony.save_ivr(menu(), subject)

    assert {:ok, %{enabled: false, version: 1}} =
             Telephony.save_ivr(%{menu() | enabled: false}, subject)

    assert {:error, :stale_version} = Telephony.save_ivr(%{menu() | enabled: false}, subject)
  end

  test "IVR reserves original 45-second caller budget without offering a member or credentials" do
    {_account, subject} = ready()
    assert {:ok, _} = Telephony.save_ivr(menu(), subject)
    assert {:ok, view, :applied} = Telephony.callback(incoming(), LiveKit)
    call = Repo.get!(Call, view.id)
    run = Repo.get_by!(IvrRun, call_id: call.id)
    assert call.routing_status == "ivr" and call.offered_user_ids == []
    assert run.expires_at == call.expires_at
    assert DateTime.diff(call.expires_at, call.started_at, :second) == 45
    assert {:ok, %{calls: []}} = Telephony.list_calls(subject, %{scope: "active"})
    assert {:error, :not_found} = Telephony.get_call(call.id, subject)

    assert {:error, :not_found} =
             Telephony.answer(call.id, subject, fn _ -> flunk("no IVR credential") end)
  end

  test "read-only observation preserves unconsumed and consumed effect claim identity" do
    {_account, subject} = ready()
    {call, run, claim} = prepare(subject)
    before = Repo.get!(IvrRun, run.id)
    assert {:ok, {:wait, 1}} = Telephony.advance_ivr(run.id, TelephonyIvrWorker)
    assert Repo.get!(IvrRun, run.id).effect_claim_fingerprint == before.effect_claim_fingerprint
    assert {:ok, {:wait, 1}} = Telephony.execute_ivr_claim(claim, TelephonyIvrWorker)
    assert_receive {:ivr_play, %{call_id: id, reconcile: false}}
    assert id == call.id

    assert {:error, :telephony_ivr_claim_consumed} =
             Telephony.execute_ivr_claim(claim, TelephonyIvrWorker)

    refute_receive {:ivr_play, _}

    # Model the durable-consumed/before-forward boundary without inventing a
    # new nonce. A separate real-wait race test must qualify the lock schedule.
    Repo.get!(IvrRun, run.id)
    |> IvrRun.changeset(%{failure_reason: "play_claimed"})
    |> Repo.update!()

    consumed = Repo.get!(IvrRun, run.id)
    assert {:ok, {:wait, 1}} = Telephony.advance_ivr(run.id, TelephonyIvrWorker)
    observed = Repo.get!(IvrRun, run.id)

    assert {observed.phase, observed.failure_reason, observed.effect_claim_fingerprint,
            observed.effect_started_at} ==
             {consumed.phase, consumed.failure_reason, consumed.effect_claim_fingerprint,
              consumed.effect_started_at}

    refute_receive {:ivr_play, _}
  end

  test "the registered worker consumes one playback claim and retries by read-only observation" do
    {_account, subject} = ready()
    assert {:ok, _} = Telephony.save_ivr(menu(), subject)
    assert {:ok, call, :applied} = Telephony.callback(incoming(), LiveKit)
    run = Repo.get_by!(IvrRun, call_id: call.id)
    job = %Oban.Job{args: %{"run_id" => run.id}}
    assert {:snooze, 1} = TelephonyIvrWorker.perform(job)
    assert {:snooze, 1} = TelephonyIvrWorker.perform(job)
    assert {:snooze, 1} = TelephonyIvrWorker.perform(job)
    assert_receive {:ivr_play, %{reconcile: false}}
    assert Repo.get!(IvrRun, run.id).effect_started_at
    assert {:snooze, 1} = TelephonyIvrWorker.perform(job)
    refute_receive {:ivr_play, _}
  end

  test "original provider digit time before prompt proof cannot select a branch when delivered later" do
    {_account, subject} = ready()
    {call, run, claim} = prepare(subject)
    assert {:ok, {:wait, 1}} = Telephony.execute_ivr_claim(claim, TelephonyIvrWorker)
    run = Repo.get!(IvrRun, run.id)
    completed = DateTime.add(run.inserted_at, 1, :microsecond)
    assert {:ok, :applied} = webhook(playback(call, run, completed))

    assert {:ok, :ignored} =
             webhook(caller_event(call, run, "ChannelDtmfReceived", run.inserted_at))

    assert Repo.get!(IvrRun, run.id).phase == :awaiting_digit

    assert {:ok, :applied} =
             webhook(
               caller_event(
                 call,
                 run,
                 "ChannelDtmfReceived",
                 DateTime.add(completed, 1, :microsecond)
               )
             )

    assert {:ok, :complete} = Telephony.advance_ivr(run.id, TelephonyIvrWorker)
    assert Repo.get!(IvrRun, run.id).phase == :completed
    assert Repo.get!(Call, call.id).status == :no_answer
  end

  test "caller disconnect and owner expiry terminate pending runs without a destination effect" do
    {_account, subject} = ready()
    {call, run, _claim} = prepare(subject)

    assert {:ok, :complete} =
             webhook(caller_event(call, run, "ChannelDestroyed", DateTime.utc_now()))

    assert Repo.get!(IvrRun, run.id).phase == :failed
    refute_receive {:ivr_destination, _}

    assert {:ok, second, :applied} =
             Telephony.callback(
               %{incoming() | event_id: "second", room: "kc_tel_inbound_second"},
               LiveKit
             )

    second_run = Repo.get_by!(IvrRun, call_id: second.id)

    Repo.get!(Call, second.id)
    |> Call.changeset(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    |> Repo.update!()

    assert {:ok, :expired} = Telephony.expire(second.id, TelephonyExpiryWorker)
    assert Repo.get!(IvrRun, second_run.id).phase == :cancelled
  end

  test "explicit Away prevents current routing offers and expires to prior eligibility" do
    {account, subject} = ready()

    assert {:ok, _} =
             Telephony.save_route(
               %{
                 name: "Support",
                 mode: "shared_line",
                 policy: "simultaneous",
                 member_ids: [account.user.id],
                 max_waiting: 20,
                 max_wait_seconds: 120,
                 enabled: true,
                 reason: "Synthetic queue policy"
               },
               subject
             )

    assert {:ok, %{version: 0}} = Telephony.agent_queue_state(subject)

    assert {:ok, %{state: :away, version: 1}} =
             Telephony.set_agent_queue_state(
               %{state: "away", duration_seconds: 60, version: 0},
               subject
             )

    assert {:ok, blocked, :ignored} = Telephony.callback(incoming(), LiveKit)
    assert blocked.status == :failed

    assert {:error, :stale_version} =
             Telephony.set_agent_queue_state(
               %{state: "ready", duration_seconds: 60, version: 0},
               subject
             )

    state = Repo.get_by!(AgentState, user_id: account.user.id)

    Repo.update_all(from(s in AgentState, where: s.id == ^state.id),
      set: [
        updated_at: DateTime.add(DateTime.utc_now(), -120, :second),
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      ]
    )

    assert {:ok, %{state: :ready, explicit: false}} = Telephony.agent_queue_state(subject)

    assert {:ok, 1} =
             Repo.transaction(fn ->
               {:ok, count} =
                 Telephony.erase_agent_queue_state(account.tenant.id, account.user.id)

               count
             end)

    refute Repo.exists?(from(s in AgentState, where: s.user_id == ^account.user.id))
  end

  test "a selected queue preserves original admission deadline and cannot obtain expiry grace or late voicemail" do
    {account, subject} = ready()

    assert {:ok, route} =
             Telephony.save_route(
               %{
                 name: "Support",
                 mode: "queue",
                 policy: "round_robin",
                 member_ids: [account.user.id],
                 max_waiting: 10,
                 max_wait_seconds: 120,
                 enabled: true,
                 reason: "Synthetic bounded queue"
               },
               subject
             )

    target = %{"kind" => "route", "route_id" => route.id}
    {call, run, claim} = prepare(subject, %{menu() | choices: %{"1" => target}})
    assert {:ok, {:wait, 1}} = Telephony.execute_ivr_claim(claim, TelephonyIvrWorker)
    completed = DateTime.add(run.inserted_at, 1, :microsecond)
    assert {:ok, :applied} = webhook(playback(call, run, completed))

    assert {:ok, :applied} =
             webhook(
               caller_event(
                 call,
                 run,
                 "ChannelDtmfReceived",
                 DateTime.add(completed, 1, :microsecond)
               )
             )

    assert {:ok, :complete} = Telephony.advance_ivr(run.id, TelephonyIvrWorker)
    selected = Repo.get!(Call, call.id)
    assert selected.expires_at == call.expires_at
    assert selected.route_expires_at == call.expires_at
    assert Repo.get!(IvrRun, run.id).phase == :completed
    expired = DateTime.add(DateTime.utc_now(), -1, :second)

    selected
    |> Call.changeset(%{
      routing_status: "waiting",
      expires_at: expired,
      route_expires_at: expired
    })
    |> Repo.update!()

    assert {:error, :call_ended} =
             Telephony.enqueue_route_voicemail(call.id, CommsWorkers.TelephonyRoutingWorker)

    assert {:ok, :expired} = Telephony.expire(call.id, TelephonyExpiryWorker)
    assert Repo.get!(Call, call.id).status == :no_answer
  end

  defp ready do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, _} =
             Telephony.provision(
               %{
                 phone_number: "+14155550100",
                 extension: "101",
                 user_id: account.user.id,
                 inbound_trunk_id: "ST_inbound",
                 outbound_trunk_id: "ST_outbound",
                 reason: "Synthetic IVR provisioning"
               },
               subject
             )

    {account, subject}
  end

  defp menu,
    do: %{
      name: "Caller menu",
      prompt_media: "sound:custom/menu",
      choices: %{"1" => %{"kind" => "hangup"}},
      fallback: %{"kind" => "hangup"},
      digit_timeout_seconds: 10,
      max_retries: 1,
      enabled: true,
      version: 0,
      reason: "Synthetic caller menu"
    }

  defp incoming,
    do: %{
      event_id: "ivr-incoming",
      event_type: "participant_joined",
      room: "kc_tel_inbound_ivr_fixture",
      participant_identity: "sip-fixture",
      participant_kind: :sip,
      participant_sid: "PA_ivr",
      provider_call_id: "SC_ivr",
      trunk_id: "ST_inbound",
      from_number: "+14155550200",
      to_number: "+14155550100"
    }

  defp prepare(subject, attributes \\ menu()) do
    assert {:ok, _} = Telephony.save_ivr(attributes, subject)
    assert {:ok, view, :applied} = Telephony.callback(incoming(), LiveKit)
    call = Repo.get!(Call, view.id)
    run = Repo.get_by!(IvrRun, call_id: call.id)
    assert {:ok, {:wait, 1}} = Telephony.advance_ivr(run.id, TelephonyIvrWorker)
    assert {:ok, {:wait, 1}} = Telephony.advance_ivr(run.id, TelephonyIvrWorker)
    assert {:ok, {:effect, claim}} = Telephony.advance_ivr(run.id, TelephonyIvrWorker)
    {call, Repo.get!(IvrRun, run.id), claim}
  end

  defp playback(_call, run, timestamp),
    do: %{
      type: "PlaybackFinished",
      event_id: receipt(),
      timestamp: DateTime.to_iso8601(timestamp),
      playback: %{
        id: CommsCore.Telephony.IvrStateMachine.playback_id(run.id, run.step),
        state: "done",
        media_uri: "sound:custom/menu",
        target_uri: "channel:" <> run.bindings["external"]
      }
    }

  defp caller_event(call, run, type, timestamp),
    do: %{
      type: type,
      event_id: receipt(),
      timestamp: DateTime.to_iso8601(timestamp),
      digit: "1",
      channel: %{
        id: run.bindings["external"],
        channelvars: %{
          KC_TENANT_ID: call.tenant_id,
          KC_CALL_ID: call.id,
          KC_LIVEKIT_ROOM: call.provider_room,
          KC_SIP_IDENTITY: call.provider_identity,
          KC_ROLE: "external",
          KC_IVR_RUN_ID: run.id,
          KC_IVR_STEP: Integer.to_string(run.step)
        }
      }
    }

  defp receipt, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp webhook(event) do
    body = Jason.encode!(event)
    timestamp = Integer.to_string(System.system_time(:second))

    signature =
      :crypto.mac(:hmac, :sha256, @secret, timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    Telephony.handle_ivr_webhook(body, "v1:" <> timestamp <> ":" <> signature)
  end
end
