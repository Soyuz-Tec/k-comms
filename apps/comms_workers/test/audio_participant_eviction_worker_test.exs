defmodule CommsWorkers.AudioParticipantEvictionWorkerTest.ScriptedRoomService do
  def delete_room(provider_room) when is_binary(provider_room), do: :ok

  def remove_participant(provider_room, identity)
      when is_binary(provider_room) and is_binary(identity) do
    agent = Application.fetch_env!(:comms_workers, :audio_eviction_test_agent)

    scripted_result =
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {:ok, []}
      end)

    result =
      case scripted_result do
        {:block, final_result} ->
          send(Application.fetch_env!(:comms_workers, :audio_eviction_test_pid), {
            :provider_removal_started,
            self(),
            provider_room,
            identity
          })

          receive do
            :release_audio_eviction_provider -> final_result
          end

        final_result ->
          final_result
      end

    send(Application.fetch_env!(:comms_workers, :audio_eviction_test_pid), {
      :provider_removal,
      provider_room,
      identity,
      result
    })

    result
  end
end

defmodule CommsWorkers.AudioParticipantEvictionWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant, CredentialRequest}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.AudioParticipantEvictionWorker

  setup do
    previous_adapter =
      Application.get_env(:comms_integrations, :audio_room_service_adapter)

    {:ok, agent} = start_supervised({Agent, fn -> [] end})

    Application.put_env(
      :comms_integrations,
      :audio_room_service_adapter,
      CommsWorkers.AudioParticipantEvictionWorkerTest.ScriptedRoomService
    )

    Application.put_env(:comms_workers, :audio_eviction_test_agent, agent)
    Application.put_env(:comms_workers, :audio_eviction_test_pid, self())

    on_exit(fn ->
      if is_nil(previous_adapter),
        do: Application.delete_env(:comms_integrations, :audio_room_service_adapter),
        else:
          Application.put_env(
            :comms_integrations,
            :audio_room_service_adapter,
            previous_adapter
          )

      Application.delete_env(:comms_workers, :audio_eviction_test_agent)
      Application.delete_env(:comms_workers, :audio_eviction_test_pid)
    end)

    %{agent: agent}
  end

  test "provider failures past the minimum horizon remain pending until a later success", %{
    agent: agent
  } do
    {call, participant} = admitted_and_revoked()
    set_enforcement_deadline(participant, DateTime.add(now(), -1, :second))
    Agent.update(agent, fn _ -> [{:error, :timeout}, :ok] end)
    job = %Oban.Job{args: %{"participant_id" => participant.id}}

    assert {:snooze, 15} = AudioParticipantEvictionWorker.perform(job)

    assert_receive {:provider_removal, room, identity, {:error, :timeout}}
    assert room == call.provider_room
    assert identity == participant.provider_identity

    failed = Repo.get!(AudioCallParticipant, participant.id)
    assert failed.status == :revoked
    assert failed.eviction_status == :pending
    assert failed.eviction_attempts == 1
    assert is_nil(failed.last_eviction_success_at)

    assert :ok = AudioParticipantEvictionWorker.perform(job)
    assert_receive {:provider_removal, ^room, ^identity, :ok}

    completed = Repo.get!(AudioCallParticipant, participant.id)
    assert completed.status == :evicted
    assert completed.eviction_status == :completed
    assert completed.eviction_attempts == 2
    assert completed.last_eviction_success_at
    assert completed.evicted_at
  end

  test "successful removal repeats throughout the minimum enforcement horizon", %{agent: agent} do
    {_call, participant} = admitted_and_revoked()
    Agent.update(agent, fn _ -> [:ok, :ok] end)
    job = %Oban.Job{args: %{"participant_id" => participant.id}}

    assert {:snooze, 30} = AudioParticipantEvictionWorker.perform(job)

    enforcing = Repo.get!(AudioCallParticipant, participant.id)
    assert enforcing.status == :evicted
    assert enforcing.eviction_status == :enforcing
    assert enforcing.eviction_attempts == 1
    assert enforcing.last_eviction_success_at

    set_enforcement_deadline(enforcing, DateTime.add(now(), -1, :second))
    assert :ok = AudioParticipantEvictionWorker.perform(job)

    completed = Repo.get!(AudioCallParticipant, participant.id)
    assert completed.eviction_status == :completed
    assert completed.eviction_attempts == 2

    assert DateTime.compare(completed.last_eviction_success_at, completed.eviction_enforce_until) !=
             :lt
  end

  test "a response crossing the cutoff cannot complete an attempt that started before it", %{
    agent: agent
  } do
    {_call, participant} = admitted_and_revoked()
    Agent.update(agent, fn _ -> [{:block, :ok}, :ok] end)
    job = %Oban.Job{args: %{"participant_id" => participant.id}}

    first_attempt = Task.async(fn -> AudioParticipantEvictionWorker.perform(job) end)

    assert_receive {:provider_removal_started, provider_pid, _room, _identity}
    cutoff = DateTime.add(now(), 10_000, :microsecond)
    set_enforcement_deadline(participant, cutoff)
    Process.sleep(15)
    send(provider_pid, :release_audio_eviction_provider)

    assert {:snooze, 30} = Task.await(first_attempt, 5_000)
    enforcing = Repo.get!(AudioCallParticipant, participant.id)
    assert enforcing.eviction_status == :enforcing
    assert DateTime.compare(enforcing.last_eviction_success_at, cutoff) == :lt

    assert :ok = AudioParticipantEvictionWorker.perform(job)
    completed = Repo.get!(AudioCallParticipant, participant.id)
    assert completed.eviction_status == :completed
    assert DateTime.compare(completed.last_eviction_success_at, cutoff) != :lt
  end

  test "invalid and already completed jobs terminate idempotently", %{agent: agent} do
    assert {:discard, :participant_id_required} =
             AudioParticipantEvictionWorker.perform(%Oban.Job{args: %{}})

    {_call, participant} = admitted_and_revoked()
    set_enforcement_deadline(participant, DateTime.add(now(), -1, :second))
    Agent.update(agent, fn _ -> [:ok] end)
    job = %Oban.Job{args: %{"participant_id" => participant.id}}

    assert :ok = AudioParticipantEvictionWorker.perform(job)
    assert :ok = AudioParticipantEvictionWorker.perform(job)
  end

  defp admitted_and_revoked do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    {:ok, call_view, :created} = AudioCalls.start(account.conversation.id, subject)

    {:ok, ^call_view, _credential} =
      AudioCalls.with_join_authorized(
        account.conversation.id,
        call_view.id,
        subject,
        fn %CredentialRequest{provider_identity: provider_identity} ->
          {:ok, provider_identity}
        end
      )

    call = Repo.get!(AudioCall, call_view.id)
    participant = Repo.get_by!(AudioCallParticipant, audio_call_id: call_view.id)

    {:ok, 1} =
      AudioCalls.revoke_for_sessions(account.tenant.id, [account.session.id], "session_revoked")

    {call, Repo.get!(AudioCallParticipant, participant.id)}
  end

  defp set_enforcement_deadline(participant, deadline) do
    participant
    |> Ecto.Changeset.change(%{eviction_enforce_until: deadline})
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
