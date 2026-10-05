defmodule CommsWorkers.AuditHistorySnapshotPurgeWorkerTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.Audit.ResourceHistorySnapshot
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.AuditHistorySnapshotPurgeWorker

  setup do
    account = Fixtures.account_fixture()
    expired = DateTime.add(DateTime.utc_now(), -7_200, :second)

    rows =
      for _ <- 1..1_001 do
        %{
          id: Ecto.UUID.generate(),
          tenant_id: account.tenant.id,
          resource_type: "deletion_request",
          resource_id: Ecto.UUID.generate(),
          actions: ["deletion_request.create"],
          origin_action: "deletion_request.create",
          event_ids: [],
          truncated: false,
          observed_at: expired,
          expires_at: DateTime.add(expired, 3_600, :second)
        }
      end

    Repo.insert_all(ResourceHistorySnapshot, rows)
    :ok
  end

  test "one execution purges1000 and schedules demand continuation, never an unbounded loop" do
    parent = self()

    assert :ok =
             AuditHistorySnapshotPurgeWorker.perform(%Oban.Job{args: %{}}, fn changeset ->
               send(parent, {:continuation, Ecto.Changeset.get_field(changeset, :args)})
               {:ok, %Oban.Job{}}
             end)

    assert_receive {:continuation, %{"continue" => true}}
    assert Repo.aggregate(ResourceHistorySnapshot, :count) == 1

    assert :ok =
             AuditHistorySnapshotPurgeWorker.perform(
               %Oban.Job{args: %{"continue" => true}},
               fn _ ->
                 flunk("a final bounded batch must not schedule a further job")
               end
             )

    assert Repo.aggregate(ResourceHistorySnapshot, :count) == 0
  end

  test "scheduling failure preserves expired-only purge and reports an explicit retryable code" do
    assert {:error, :history_snapshot_purge_scheduling_failed} =
             AuditHistorySnapshotPurgeWorker.perform(%Oban.Job{args: %{}}, fn _ ->
               {:error, :synthetic_failure}
             end)

    assert Repo.aggregate(ResourceHistorySnapshot, :count) == 1
  end
end
