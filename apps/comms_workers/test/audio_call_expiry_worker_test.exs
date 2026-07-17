defmodule CommsWorkers.AudioCallExpiryWorkerTest.ScriptedRoomService do
  def delete_room(call) do
    agent = Application.fetch_env!(:comms_workers, :audio_expiry_test_agent)

    result =
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {:ok, []}
      end)

    send(Application.fetch_env!(:comms_workers, :audio_expiry_test_pid), {
      :delete_expired_audio_room,
      call.provider_room,
      result
    })

    result
  end

  def remove_participant(_call, _identity), do: :ok
end

defmodule CommsWorkers.AudioCallExpiryWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}
  alias CommsCore.Audit
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.AudioCallExpiryWorker

  setup do
    previous_adapter = Application.get_env(:comms_integrations, :audio_room_service_adapter)
    {:ok, agent} = start_supervised({Agent, fn -> [] end})

    Application.put_env(
      :comms_integrations,
      :audio_room_service_adapter,
      CommsWorkers.AudioCallExpiryWorkerTest.ScriptedRoomService
    )

    Application.put_env(:comms_workers, :audio_expiry_test_agent, agent)
    Application.put_env(:comms_workers, :audio_expiry_test_pid, self())

    on_exit(fn ->
      if is_nil(previous_adapter),
        do: Application.delete_env(:comms_integrations, :audio_room_service_adapter),
        else:
          Application.put_env(
            :comms_integrations,
            :audio_room_service_adapter,
            previous_adapter
          )

      Application.delete_env(:comms_workers, :audio_expiry_test_agent)
      Application.delete_env(:comms_workers, :audio_expiry_test_pid)
    end)

    %{agent: agent}
  end

  test "expires an occupied room through the normal ended lifecycle", %{agent: agent} do
    {account, call, participant} = expired_occupied_call()
    Agent.update(agent, fn _ -> [:ok] end)

    assert :ok =
             AudioCallExpiryWorker.perform(%Oban.Job{args: %{"call_id" => call.id}})

    assert_receive {:delete_expired_audio_room, provider_room, :ok}
    assert provider_room == call.provider_room

    ended = Repo.get!(AudioCall, call.id)
    assert ended.status == :ended
    assert ended.end_reason == "expired"
    assert is_nil(ended.ended_by_user_id)

    revoked = Repo.get!(AudioCallParticipant, participant.id)
    assert revoked.status == :revoked
    assert revoked.revocation_reason == "call_expired"
    assert revoked.eviction_status == :pending

    assert Repo.get_by!(OutboxEvent,
             aggregate_id: call.id,
             event_type: "audio_call.ended.v1"
           )

    audit =
      Audit.get_by!(%{
        tenant_id: account.tenant.id,
        resource_id: call.id,
        action: "audio_call.end"
      })

    assert audit.tenant_id == account.tenant.id
    assert is_nil(audit.actor_user_id)

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
                   fragment("?->>'participant_id'", job.args) == ^participant.id
             )
           )
  end

  test "provider failure leaves expiry active and retries durably until deletion succeeds", %{
    agent: agent
  } do
    {_account, call, participant} = expired_occupied_call()
    Agent.update(agent, fn _ -> [{:error, :audio_provider_unavailable}, :ok] end)
    job = %Oban.Job{args: %{"call_id" => call.id}}

    assert {:snooze, 15} = AudioCallExpiryWorker.perform(job)
    assert_receive {:delete_expired_audio_room, _room, {:error, :audio_provider_unavailable}}
    assert Repo.get!(AudioCall, call.id).status == :active
    assert Repo.get!(AudioCallParticipant, participant.id).status == :admitted

    refute Repo.get_by(OutboxEvent,
             aggregate_id: call.id,
             event_type: "audio_call.ended.v1"
           )

    assert :ok = AudioCallExpiryWorker.perform(job)
    assert_receive {:delete_expired_audio_room, _room, :ok}
    assert Repo.get!(AudioCall, call.id).status == :ended
  end

  test "not-due and already-ended expiry jobs are idempotent without provider calls" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    job = %Oban.Job{args: %{"call_id" => call.id}}

    assert {:snooze, seconds} = AudioCallExpiryWorker.perform(job)
    assert seconds > 0
    refute_received {:delete_expired_audio_room, _room, _result}

    {:ok, ended} =
      AudioCalls.end_call(
        account.conversation.id,
        call.id,
        %{reason: "owner_ended"},
        subject,
        fn _ending_call -> :ok end
      )

    assert ended.status == :ended
    assert :ok = AudioCallExpiryWorker.perform(job)
    refute_received {:delete_expired_audio_room, _room, _result}

    assert {:discard, :call_id_required} =
             AudioCallExpiryWorker.perform(%Oban.Job{args: %{}})
  end

  defp expired_occupied_call do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)

    {:ok, ^call, _credential} =
      AudioCalls.with_join_authorized(
        account.conversation.id,
        call.id,
        subject,
        fn _locked_call, participant -> {:ok, participant.provider_identity} end
      )

    timestamp = now()

    expired =
      call
      |> Ecto.Changeset.change(%{
        started_at: DateTime.add(timestamp, -3_600, :second),
        expires_at: DateTime.add(timestamp, -1, :second)
      })
      |> Repo.update!()

    participant = Repo.get_by!(AudioCallParticipant, audio_call_id: call.id)
    {account, expired, participant}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
