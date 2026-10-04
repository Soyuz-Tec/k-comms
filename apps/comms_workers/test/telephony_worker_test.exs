defmodule CommsWorkers.TelephonyWorkerTest.ScriptedProvider do
  def create_outbound(command), do: effect(:create, command)
  def get_participant(room, identity), do: effect(:get, {room, identity})
  def end_call(room), do: effect(:end, room)

  defp effect(kind, value) do
    agent = Application.fetch_env!(:comms_workers, :telephony_test_agent)

    result =
      Agent.get_and_update(agent, fn script ->
        case Map.get(script, kind, []) do
          [next | rest] -> {next, Map.put(script, kind, rest)}
          [] -> {{:error, :telephony_provider_unavailable}, script}
        end
      end)

    send(Application.fetch_env!(:comms_workers, :telephony_test_pid), {kind, value, result})
    result
  end
end

defmodule CommsWorkers.TelephonyWorkerTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :call
  @moduletag :failure_recovery

  alias CommsCore.{Accounts, Administration, AudioCalls, Governance, Repo, Telephony}
  alias CommsCore.AudioCalls.AudioCallParticipant
  alias CommsCore.Telephony.{Call, Number, ProviderCommand}
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.{TelephonyCleanupWorker, TelephonyDispatchWorker, TelephonyExpiryWorker}

  setup do
    options = [
      telephony_provider_mode: "livekit",
      telephony_adapter: CommsWorkers.TelephonyWorkerTest.ScriptedProvider,
      audio_provider_mode: "livekit",
      livekit_api_url: "http://127.0.0.1:7880",
      livekit_server_url: "ws://127.0.0.1:7880",
      livekit_api_key: "synthetic-test-key",
      livekit_api_secret: "synthetic-test-secret-with-more-than-32-bytes",
      allow_insecure_local_media: true
    ]

    previous =
      Enum.map(options, fn {key, _} -> {key, Application.get_env(:comms_integrations, key)} end)

    Enum.each(options, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    {:ok, agent} = start_supervised({Agent, fn -> %{} end})
    Application.put_env(:comms_workers, :telephony_test_agent, agent)
    Application.put_env(:comms_workers, :telephony_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:comms_integrations, key)
        {key, value} -> Application.put_env(:comms_integrations, key, value)
      end)

      Application.delete_env(:comms_workers, :telephony_test_agent)
      Application.delete_env(:comms_workers, :telephony_test_pid)
    end)

    %{agent: agent}
  end

  test "the telephone leg waits for a verified browser join", %{agent: agent} do
    {_account, call} = phone_fixture(%{app_connected_at: nil})
    Agent.update(agent, fn _ -> %{create: [answered_result(call)]} end)

    assert {:snooze, seconds} = TelephonyDispatchWorker.perform(job(call))
    assert seconds > 0
    assert Repo.get!(Call, call.id).dispatch_status == :pending
    refute_received {:create, _, _}
  end

  test "a dispatched leg is persisted as answered without a second provider create", %{
    agent: agent
  } do
    {_account, call} = phone_fixture()
    Agent.update(agent, fn _ -> %{create: [answered_result(call)]} end)

    assert :ok = TelephonyDispatchWorker.perform(job(call))
    assert_receive {:create, %ProviderCommand{call_id: call_id, reconcile: false}, _}
    assert call_id == call.id

    answered = Repo.get!(Call, call.id)
    assert answered.status == :answered
    assert answered.dispatch_status == :started
    assert answered.provider_call_id == "SC_synthetic"
    assert answered.answered_at

    assert :ok = TelephonyDispatchWorker.perform(job(call))
    refute_received {:create, _, _}
  end

  test "inbound browser admission stays ringing until the existing SIP leg is active", %{
    agent: agent
  } do
    {account, call} = phone_fixture(%{direction: :inbound})
    {:ok, active_leg} = answered_result(call)

    Agent.update(agent, fn _ ->
      %{get: [{:ok, %{active_leg | state: :ringing}}, {:ok, active_leg}]}
    end)

    assert {:snooze, 5} = TelephonyDispatchWorker.perform(job(call))
    assert_receive {:get, {room, identity}, {:ok, %{state: :ringing}}}
    assert room == call.provider_room
    assert identity == call.provider_identity
    ringing = Repo.get!(Call, call.id)
    assert ringing.status == :ringing
    assert is_nil(ringing.answered_at)
    refute_received {:create, _, _}

    observed_active_at = now()
    assert :ok = TelephonyDispatchWorker.perform(job(call))
    assert_receive {:get, {^room, ^identity}, {:ok, %{state: :answered}}}
    answered = Repo.get!(Call, call.id)
    assert answered.status == :answered
    assert DateTime.compare(answered.answered_at, observed_active_at) != :lt
    assert {:ok, view} = Telephony.get_call(call.id, Fixtures.subject(account))
    assert view.connected_seconds >= 0
    refute_received {:create, _, _}
  end

  test "an inbound leg ending before a confirmed answer records an unconfirmed failure", %{
    agent: agent
  } do
    {account, call} = phone_fixture(%{direction: :inbound})
    {:ok, participant} = answered_result(call)
    Agent.update(agent, fn _ -> %{get: [{:ok, %{participant | state: :ended}}]} end)

    assert :ok = TelephonyDispatchWorker.perform(job(call))
    assert_receive {:get, {room, identity}, {:ok, %{state: :ended}}}
    assert room == call.provider_room
    assert identity == call.provider_identity
    refute_received {:create, _, _}

    failed = Repo.get!(Call, call.id)
    assert failed.status == :failed
    assert failed.end_reason == "answer_unconfirmed"
    assert is_nil(failed.answered_at)
    assert_cleanup_enqueued(call.id)

    subject = Fixtures.subject(account)
    assert {:ok, view} = Telephony.get_call(call.id, subject)
    assert view.connected_seconds == 0
    assert {:ok, %{calls: []}} = Telephony.list_calls(subject, %{scope: :missed})
  end

  test "an interrupted durable claim reconciles the exact participant and never redials", %{
    agent: agent
  } do
    {_account, call} = phone_fixture()

    assert {:ok, %ProviderCommand{reconcile: false}} =
             Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)

    Agent.update(agent, fn _ -> %{get: [answered_result(call)]} end)

    assert :ok = TelephonyDispatchWorker.perform(job(call))
    assert_receive {:get, {room, identity}, _}
    assert room == call.provider_room
    assert identity == call.provider_identity
    assert Repo.get!(Call, call.id).status == :answered
    refute_received {:create, _, _}
  end

  test "an absent participant after a crash waits for expiry rather than creating another leg", %{
    agent: agent
  } do
    {_account, call} = phone_fixture()
    assert {:ok, %ProviderCommand{}} = Telephony.claim_dispatch(call.id, TelephonyDispatchWorker)
    original_claim = Repo.get!(Call, call.id).dispatch_claimed_at
    Agent.update(agent, fn _ -> %{get: [{:error, :not_found}]} end)

    assert {:snooze, 5} = TelephonyDispatchWorker.perform(job(call))
    assert_receive {:get, _, {:error, :not_found}}
    assert Repo.get!(Call, call.id).dispatch_status == :dispatching
    assert Repo.get!(Call, call.id).dispatch_claimed_at == original_claim
    refute_received {:create, _, _}

    due(call)
    assert :ok = TelephonyExpiryWorker.perform(job(call))
    assert Repo.get!(Call, call.id).status == :no_answer
    assert :ok = TelephonyDispatchWorker.perform(job(call))
    refute_received {:create, _, _}
  end

  test "ambiguous provider failures terminate safely and enqueue cleanup without redial", %{
    agent: agent
  } do
    {_account, call} = phone_fixture()
    Agent.update(agent, fn _ -> %{create: [{:error, :telephony_outcome_unknown}]} end)

    assert :ok = TelephonyDispatchWorker.perform(job(call))
    assert_receive {:create, _, {:error, :telephony_outcome_unknown}}
    failed = Repo.get!(Call, call.id)
    assert failed.status == :failed
    assert failed.end_reason == "provider_outcome_unknown"
    assert_cleanup_enqueued(call.id)
    assert :ok = TelephonyDispatchWorker.perform(job(call))
    refute_received {:create, _, _}
  end

  test "expiry enforces both the ringing and connected-call deadlines" do
    {_account, ringing} = phone_fixture()
    assert {:snooze, seconds} = TelephonyExpiryWorker.perform(job(ringing))
    assert seconds > 0
    due(ringing)
    assert :ok = TelephonyExpiryWorker.perform(job(ringing))
    assert Repo.get!(Call, ringing.id).status == :no_answer
    assert :ok = TelephonyExpiryWorker.perform(job(ringing))
    assert_cleanup_enqueued(ringing.id)

    {_account, connected} =
      phone_fixture(%{status: :answered, answered_at: now(), dispatch_status: :started})

    due(connected)
    assert :ok = TelephonyExpiryWorker.perform(job(connected))
    ended = Repo.get!(Call, connected.id)
    assert ended.status == :ended
    assert ended.end_reason == "maximum_duration"
    assert_cleanup_enqueued(connected.id)
  end

  test "cleanup retries failures and continues deletion while a SIP create may arrive late", %{
    agent: agent
  } do
    {_account, call} = phone_fixture(%{dispatch_status: :dispatching, dispatch_claimed_at: now()})
    due(call)
    assert :ok = TelephonyExpiryWorker.perform(job(call))
    Agent.update(agent, fn _ -> %{end: [{:error, :telephony_provider_unavailable}, :ok, :ok]} end)

    assert {:snooze, 15} = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:end, room, {:error, :telephony_provider_unavailable}}
    assert room == call.provider_room
    failed = Repo.get!(Call, call.id)
    assert is_nil(failed.cleanup_completed_at)
    assert is_nil(failed.cleanup_claimed_at)

    assert {:snooze, 5} = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:end, ^room, :ok}
    assert is_nil(Repo.get!(Call, call.id).cleanup_completed_at)

    age_claim(call)
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    assert_receive {:end, ^room, :ok}
    assert Repo.get!(Call, call.id).cleanup_completed_at
    assert :ok = TelephonyCleanupWorker.perform(job(call))
    refute_received {:end, _, _}
  end

  test "logout, device revocation, and user suspension terminate phone and conversation admissions" do
    for operation <- [:logout, :device, :suspend] do
      {account, call} =
        phone_fixture(%{status: :answered, answered_at: now(), dispatch_status: :started})

      subject = Fixtures.subject(account)
      {:ok, audio_call, :created} = AudioCalls.start(account.conversation.id, subject)

      {:ok, _view, participant_id} =
        AudioCalls.with_join_authorized(
          account.conversation.id,
          audio_call.id,
          subject,
          fn request -> {:ok, request.participant_id} end
        )

      case operation do
        :logout ->
          assert :ok = Accounts.revoke_session(account.session.id, account.user.id)

        :device ->
          assert {:ok, _} = Accounts.revoke_device(account.device.id, subject)

        :suspend ->
          Fixtures.user_fixture(account, %{role: :owner})

          {:ok, _} =
            Governance.change_user_lifecycle_view(
              account.user.id,
              %{
                version: account.user.lock_version,
                status: "suspended",
                reason: "Synthetic revocation test"
              },
              Fixtures.step_up(account)
            )
      end

      assert Repo.get!(Call, call.id).status == :ended
      assert Repo.get!(AudioCallParticipant, participant_id).status == :revoked
      assert_cleanup_enqueued(call.id)
    end
  end

  test "disabling tenant audio ends its telephone leg; disabling video leaves it active" do
    for media_kind <- [:video, :audio] do
      {account, call} =
        phone_fixture(%{status: :answered, answered_at: now(), dispatch_status: :started})

      subject = Fixtures.step_up(account)
      field = if media_kind == :audio, do: :allow_audio_calls, else: :allow_video_calls

      assert {:ok, _} =
               Administration.update_tenant_settings(%{field => false, version: 1}, subject)

      expected = if media_kind == :audio, do: :ended, else: :answered
      assert Repo.get!(Call, call.id).status == expected
    end
  end

  test "malformed jobs terminate without provider effects" do
    for worker <- [TelephonyDispatchWorker, TelephonyExpiryWorker, TelephonyCleanupWorker] do
      assert {:discard, :call_id_required} = worker.perform(%Oban.Job{args: %{}})

      assert {:discard, :telephony_call_not_found} =
               worker.perform(%Oban.Job{args: %{"call_id" => Ecto.UUID.generate()}})
    end

    refute_received {:create, _, _}
    refute_received {:get, _, _}
    refute_received {:end, _, _}
  end

  defp phone_fixture(overrides \\ %{}) do
    account = Fixtures.account_fixture()
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
    phone_number = "+1555" <> String.pad_leading(suffix, 7, "0")

    number =
      %Number{}
      |> Number.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        phone_number: phone_number,
        extension: "101",
        inbound_trunk_id: "ST_inbound",
        outbound_trunk_id: "ST_outbound"
      })
      |> Repo.insert!()

    timestamp = now()

    attrs =
      Map.merge(
        %{
          tenant_id: account.tenant.id,
          number_id: number.id,
          user_id: account.user.id,
          direction: :outbound,
          status: :ringing,
          from_number: phone_number,
          to_number: "+15555550199",
          extension: number.extension,
          inbound_trunk_id: number.inbound_trunk_id,
          outbound_trunk_id: number.outbound_trunk_id,
          provider_room: "telephony-" <> Ecto.UUID.generate(),
          provider_identity: "sip-" <> Ecto.UUID.generate(),
          answer_session_id: account.session.id,
          answer_device_id: account.device.id,
          app_identity: "app-" <> Ecto.UUID.generate(),
          app_connected_at: timestamp,
          app_provider_sid: "PA_" <> Ecto.UUID.generate(),
          app_event_at: timestamp,
          started_at: DateTime.add(timestamp, -20, :second),
          expires_at: DateTime.add(timestamp, 45, :second)
        },
        overrides
      )

    attrs =
      if is_nil(attrs.app_connected_at) do
        Map.merge(attrs, %{app_provider_sid: nil, app_event_at: nil})
      else
        attrs
      end

    attrs =
      if attrs.direction == :inbound do
        Map.merge(attrs, %{from_number: attrs.to_number, to_number: attrs.from_number})
      else
        attrs
      end

    call = %Call{} |> Call.changeset(attrs) |> Repo.insert!()
    {account, call}
  end

  defp answered_result(call),
    do:
      {:ok,
       %{
         state: :answered,
         provider_call_id: "SC_synthetic",
         provider_room: call.provider_room,
         provider_identity: call.provider_identity
       }}

  defp job(call), do: %Oban.Job{args: %{"call_id" => call.id}}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp due(call),
    do:
      call
      |> Ecto.Changeset.change(%{expires_at: DateTime.add(now(), -1, :second)})
      |> Repo.update!()

  defp age_claim(call),
    do:
      Repo.get!(Call, call.id)
      |> Ecto.Changeset.change(%{dispatch_claimed_at: DateTime.add(now(), -180, :second)})
      |> Repo.update!()

  defp assert_cleanup_enqueued(call_id) do
    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.TelephonyCleanupWorker" and
                   fragment("?->>'call_id'", job.args) == ^call_id
             )
           )
  end
end
