defmodule CommsCore.AudioCalls.StartConcurrencyTest do
  use CommsCore.DataCase, async: false

  @moduletag :call
  @moduletag :integration
  @moduletag :concurrency

  alias CommsCore.Accounts.Session
  alias CommsCore.Administration.{Tenant, TenantSettings}
  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{AudioCall, AudioCallParticipant}
  alias CommsCore.Audit
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  test "tenant capability race cannot commit an orphaned call" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    parent = self()

    disable_task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(tenant in Tenant,
              where: tenant.id == ^account.tenant.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, :video_capability_lock_held)

          receive do
            :disable_video_and_commit -> :ok
          end

          settings =
            Repo.get_by(TenantSettings, tenant_id: account.tenant.id) ||
              %TenantSettings{tenant_id: account.tenant.id}

          settings
          |> TenantSettings.changeset(%{allow_video_calls: false})
          |> Repo.insert_or_update!()
        end)
      end)

    assert_receive :video_capability_lock_held

    start_task =
      Task.async(fn ->
        AudioCalls.start_with_join_authorized(
          account.conversation.id,
          subject,
          :video,
          fn _call -> :ok end,
          fn _request ->
            send(parent, :capability_race_issuer_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :capability_race_issuer_ran, 100
    send(disable_task.pid, :disable_video_and_commit)
    assert {:ok, %TenantSettings{allow_video_calls: false}} = Task.await(disable_task, 5_000)
    assert {:error, :video_calls_disabled} = Task.await(start_task, 5_000)
    refute_received :capability_race_issuer_ran
    assert_no_call_start_artifacts(account.tenant.id)
  end

  test "session revocation race cannot commit an orphaned call" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    parent = self()

    revoke_task =
      Task.async(fn ->
        Repo.transaction(fn ->
          session =
            Repo.one!(
              from(session in Session,
                where: session.id == ^account.session.id,
                lock: "FOR UPDATE"
              )
            )

          send(parent, :session_revocation_lock_held)

          receive do
            :revoke_session_and_commit -> :ok
          end

          session
          |> Session.changeset(%{revoked_at: now()})
          |> Repo.update!()
        end)
      end)

    assert_receive :session_revocation_lock_held

    start_task =
      Task.async(fn ->
        AudioCalls.start_with_join_authorized(
          account.conversation.id,
          subject,
          :video,
          fn _call -> :ok end,
          fn _request ->
            send(parent, :session_race_issuer_ran)
            {:ok, :credential}
          end
        )
      end)

    refute_receive :session_race_issuer_ran, 100
    send(revoke_task.pid, :revoke_session_and_commit)
    assert {:ok, %Session{revoked_at: %DateTime{}}} = Task.await(revoke_task, 5_000)
    assert {:error, :forbidden} = Task.await(start_task, 5_000)
    refute_received :session_race_issuer_ran
    assert_no_call_start_artifacts(account.tenant.id)
  end

  test "concurrent starts resolve to one active call" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    results =
      1..3
      |> Enum.map(fn _ ->
        Task.async(fn -> AudioCalls.start(account.conversation.id, subject) end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    ids = Enum.map(results, fn {:ok, call, _status} -> call.id end)
    assert ids |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(from(call in AudioCall, where: call.status == :active), :count) == 1
  end

  defp assert_no_call_start_artifacts(tenant_id) do
    assert Repo.aggregate(AudioCall, :count) == 0
    assert Repo.aggregate(AudioCallParticipant, :count) == 0

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where: event.event_type in ["call.started.v1", "audio_call.started.v1"]
             ),
             :count
           ) == 0

    assert Audit.count(%{tenant_id: tenant_id, action: "audio_call.start"}) == 0
    assert Audit.count(%{tenant_id: tenant_id, action: "video_call.start"}) == 0

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "CommsWorkers.AudioCallExpiryWorker"
             ),
             :count
           ) == 0
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
