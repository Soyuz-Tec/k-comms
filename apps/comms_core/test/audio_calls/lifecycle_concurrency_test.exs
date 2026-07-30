defmodule CommsCore.AudioCalls.LifecycleConcurrencyTest do
  use CommsCore.DataCase, async: false

  @moduletag :call
  @moduletag :integration
  @moduletag :concurrency

  alias CommsCore.Accounts
  alias CommsCore.Administration
  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCallParticipant, CallView}
  alias CommsCore.Conversations
  alias CommsTestSupport.Fixtures

  @tag :concurrency
  test "join token issuance cannot run after ending starts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    test_pid = self()

    end_task =
      Task.async(fn ->
        AudioCalls.end_call(
          account.conversation.id,
          call.id,
          %{reason: "owner_ended"},
          subject,
          fn ending_call ->
            send(test_pid, {:provider_delete_started, ending_call.status})

            receive do
              :finish_provider_delete -> :ok
            end
          end
        )
      end)

    assert_receive {:provider_delete_started, :ending}

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _request ->
            send(test_pid, :join_token_issuer_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :join_token_issuer_ran, 100
    send(end_task.pid, :finish_provider_delete)

    assert {:ok, %CallView{status: :ended}} = Task.await(end_task, 5_000)
    assert {:error, :audio_call_ended} = Task.await(join_task, 5_000)
    refute_received :join_token_issuer_ran
  end

  @tag :concurrency
  test "an in-flight join credential completes before a later end transition" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    test_pid = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _request ->
            send(test_pid, :join_issuer_started)

            receive do
              :finish_join_issuer -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive :join_issuer_started

    end_task =
      Task.async(fn ->
        AudioCalls.end_call(
          account.conversation.id,
          call.id,
          %{reason: "owner_ended"},
          subject,
          fn ending_call ->
            send(test_pid, {:later_provider_delete_started, ending_call.status})
            :ok
          end
        )
      end)

    refute_receive {:later_provider_delete_started, _status}, 100
    send(join_task.pid, :finish_join_issuer)

    assert {:ok, %CallView{id: call_id}, :credential} = Task.await(join_task, 5_000)
    assert call_id == call.id
    assert_receive {:later_provider_delete_started, :ending}
    assert {:ok, %CallView{status: :ended}} = Task.await(end_task, 5_000)
  end

  @tag :concurrency
  test "a credential admitted before session revocation is durably queued for eviction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn request ->
            send(parent, {:issuer_locked_authority, request.participant_id})

            receive do
              :finish_credential -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive {:issuer_locked_authority, participant_id}

    revoke_task =
      Task.async(fn ->
        result = Accounts.revoke_session(account.session.id, account.user.id)
        send(parent, {:session_revoke_finished, result})
        result
      end)

    refute_receive {:session_revoke_finished, _result}, 100
    send(join_task.pid, :finish_credential)

    assert {:ok, %CallView{id: call_id}, :credential} = Task.await(join_task, 5_000)
    assert call_id == call.id
    assert :ok = Task.await(revoke_task, 5_000)
    assert_receive {:session_revoke_finished, :ok}

    participant = Repo.get!(AudioCallParticipant, participant_id)
    assert participant.status == :revoked
    assert participant.eviction_status == :pending

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.AudioParticipantEvictionWorker" and
                   fragment("?->>'participant_id'", job.args) == ^participant.id
             )
           )
  end

  @tag :concurrency
  test "session revocation holding the authority lock prevents a later credential callback" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    revoker =
      Task.async(fn ->
        Repo.transaction(fn ->
          session =
            Repo.one!(
              from(session in CommsCore.Accounts.Session,
                where: session.id == ^account.session.id,
                lock: "FOR UPDATE"
              )
            )

          session
          |> CommsCore.Accounts.Session.changeset(%{revoked_at: now()})
          |> Repo.update!()

          send(parent, :session_revocation_locked)

          receive do
            :commit_session_revocation -> :ok
          end
        end)
      end)

    assert_receive :session_revocation_locked

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn _request ->
            send(parent, :credential_callback_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :credential_callback_ran, 100
    send(revoker.pid, :commit_session_revocation)
    assert {:ok, :ok} = Task.await(revoker, 5_000)
    assert {:error, :forbidden} = Task.await(join_task, 5_000)
    refute_received :credential_callback_ran
    refute Repo.get_by(AudioCallParticipant, audio_call_id: call.id)
  end

  @tag :concurrency
  test "tenant audio disable waits for an in-flight admission then queues its eviction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn request ->
            send(parent, {:tenant_race_issuer_started, request.participant_id})

            receive do
              :finish_tenant_race_issuer -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive {:tenant_race_issuer_started, participant_id}

    disable_task =
      Task.async(fn ->
        result =
          Administration.update_tenant_settings(
            %{version: 1, allow_audio_calls: false},
            subject
          )

        send(parent, {:tenant_audio_disable_finished, result})
        result
      end)

    refute_receive {:tenant_audio_disable_finished, _result}, 100
    send(join_task.pid, :finish_tenant_race_issuer)
    assert {:ok, %CallView{}, :credential} = Task.await(join_task, 5_000)
    assert {:ok, %{settings: %{allow_audio_calls: false}}} = Task.await(disable_task, 5_000)

    participant = Repo.get!(AudioCallParticipant, participant_id)
    assert participant.status == :revoked
    assert participant.revocation_reason == "tenant_audio_disabled"
  end

  @tag :concurrency
  test "conversation archive waits for an in-flight admission then queues its eviction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, call, :created} = AudioCalls.start(account.conversation.id, subject)
    parent = self()

    join_task =
      Task.async(fn ->
        AudioCalls.with_join_authorized(
          account.conversation.id,
          call.id,
          subject,
          fn request ->
            send(parent, {:archive_race_issuer_started, request.participant_id})

            receive do
              :finish_archive_race_issuer -> {:ok, :credential}
            end
          end
        )
      end)

    assert_receive {:archive_race_issuer_started, participant_id}

    archive_task =
      Task.async(fn ->
        result =
          Conversations.archive(
            account.conversation.id,
            %{version: account.conversation.lock_version},
            subject
          )

        send(parent, {:conversation_archive_finished, result})
        result
      end)

    refute_receive {:conversation_archive_finished, _result}, 100
    send(join_task.pid, :finish_archive_race_issuer)
    assert {:ok, %CallView{}, :credential} = Task.await(join_task, 5_000)
    assert {:ok, %{archived_at: %DateTime{}}} = Task.await(archive_task, 5_000)

    participant = Repo.get!(AudioCallParticipant, participant_id)
    assert participant.status == :revoked
    assert participant.revocation_reason == "conversation_archived"
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
