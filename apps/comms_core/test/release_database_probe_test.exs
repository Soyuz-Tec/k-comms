defmodule CommsCore.ReleaseDatabaseProbeTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations, Repo, RuntimePorts}
  alias CommsCore.Accounts.{AuthenticationResult, User}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :release

  test "platform persistence returns a bounded migration snapshot" do
    assert [[application_name, lock_timeout_ms, statement_timeout_ms, peer_count]] =
             Repo.release_migration_preflight!()

    assert is_binary(application_name)
    assert is_integer(lock_timeout_ms)
    assert lock_timeout_ms >= 0
    assert is_integer(statement_timeout_ms)
    assert statement_timeout_ms >= 0
    assert is_integer(peer_count)
    assert peer_count >= 0
  end

  test "IdentityAccess counts every persisted guest identity regardless of lifecycle state" do
    account = Fixtures.account_fixture()
    initial_guest_count = Accounts.persisted_guest_identity_count()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(3_600, :second)
      |> DateTime.truncate(:microsecond)

    assert {:ok, %AuthenticationResult{user: guest}} =
             Repo.transaction(fn ->
               case Accounts.provision_guest_identity(%{
                      tenant_id: account.tenant.id,
                      display_name: "Rollback Probe Guest",
                      expires_at: expires_at,
                      device: %{name: "Probe browser", platform: "test"},
                      request_id: "rollback-probe"
                    }) do
                 {:ok, result} -> result
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert Accounts.persisted_guest_identity_count() == initial_guest_count + 1

    User
    |> Repo.get!(guest.id)
    |> Ecto.Changeset.change(%{status: :deleted, guest_expires_at: DateTime.utc_now()})
    |> Repo.update!()

    assert Accounts.persisted_guest_identity_count() == initial_guest_count + 1
  end

  test "platform persistence counts only active jobs for the exact worker" do
    worker_name = RuntimePorts.job_worker_name!(:guest_admission_expiry)
    other_worker = "CommsWorkers.UnrelatedRollbackProbe"
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    initial_worker_count = Repo.active_oban_job_count!(worker_name)
    initial_other_worker_count = Repo.active_oban_job_count!(other_worker)

    for state <- ~w(available scheduled executing retryable) do
      insert_job(worker_name, state, timestamp)
    end

    for state <- ~w(completed discarded cancelled) do
      insert_job(worker_name, state, timestamp)
    end

    insert_job(other_worker, "available", timestamp)

    assert Repo.active_oban_job_count!(worker_name) == initial_worker_count + 4
    assert Repo.active_oban_job_count!(other_worker) == initial_other_worker_count + 1
  end

  test "communication rollback probes expose bounded owner-context counts" do
    for count <- [
          Accounts.persisted_conversation_only_human_count(),
          Conversations.persisted_ephemeral_room_count(),
          Conversations.persisted_ephemeral_join_receipt_count(),
          Conversations.persisted_ephemeral_presence_lease_count()
        ] do
      assert is_integer(count)
      assert count >= 0
    end
  end

  test "platform persistence recognizes both instant-room lifecycle workers" do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for kind <- [:ephemeral_room_lifecycle, :ephemeral_room_reconciler] do
      worker_name = RuntimePorts.job_worker_name!(kind)
      initial_count = Repo.active_oban_job_count!(worker_name)

      insert_job(worker_name, "scheduled", timestamp)
      insert_job(worker_name, "completed", timestamp)

      assert Repo.active_oban_job_count!(worker_name) == initial_count + 1
    end
  end

  defp insert_job(worker_name, state, timestamp) do
    %Oban.Job{}
    |> Ecto.Changeset.change(%{
      state: state,
      queue: "default",
      worker: worker_name,
      args: %{"probe" => Ecto.UUID.generate()},
      meta: %{},
      tags: [],
      errors: [],
      attempt: 0,
      max_attempts: 20,
      priority: 0,
      inserted_at: timestamp,
      scheduled_at: timestamp
    })
    |> Repo.insert!()
  end
end
