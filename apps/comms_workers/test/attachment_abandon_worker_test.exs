defmodule CommsWorkers.AttachmentAbandonWorkerTest.Storage do
  @behaviour CommsIntegrations.ObjectStorage

  @impl true
  def purge_object_versions(request) do
    send(test_pid(), {:purge_abandoned_attachment, request})
    next(:purge)
  end

  @impl true
  def verify_upload(_attachment), do: {:error, :not_used}

  @impl true
  def delete_object(_request), do: {:error, :not_used}

  @impl true
  def presign_upload(_request), do: {:error, :not_used}

  @impl true
  def presign_download(_request), do: {:error, :not_used}

  @impl true
  def verify_restored_object(_request), do: {:error, :not_used}

  @impl true
  def status, do: %{status: :available, adapter: "attachment-abandon-test"}

  defp next(kind) do
    Agent.get_and_update(
      Application.fetch_env!(:comms_workers, :attachment_abandon_test_agent),
      fn state ->
        case Map.fetch!(state, kind) do
          [next | rest] -> {next, Map.put(state, kind, rest)}
          [] -> {{:error, :unexpected_adapter_call}, state}
        end
      end
    )
  end

  defp test_pid,
    do: Application.fetch_env!(:comms_workers, :attachment_abandon_test_pid)
end

defmodule CommsWorkers.AttachmentAbandonWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Attachments
  alias CommsCore.Attachments.Attachment
  alias CommsCore.{Repo, RuntimePorts}
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.AttachmentAbandonWorker
  alias CommsWorkers.AttachmentCleanupReconcilerWorker

  setup do
    previous_adapter = Application.get_env(:comms_integrations, :object_storage_adapter)
    previous_pid = Application.get_env(:comms_workers, :attachment_abandon_test_pid)
    previous_agent = Application.get_env(:comms_workers, :attachment_abandon_test_agent)
    {:ok, agent} = start_supervised({Agent, fn -> %{purge: []} end})

    Application.put_env(
      :comms_integrations,
      :object_storage_adapter,
      CommsWorkers.AttachmentAbandonWorkerTest.Storage
    )

    Application.put_env(:comms_workers, :attachment_abandon_test_pid, self())
    Application.put_env(:comms_workers, :attachment_abandon_test_agent, agent)

    on_exit(fn ->
      restore_env(:comms_integrations, :object_storage_adapter, previous_adapter)
      restore_env(:comms_workers, :attachment_abandon_test_pid, previous_pid)
      restore_env(:comms_workers, :attachment_abandon_test_agent, previous_agent)
    end)

    %{agent: agent}
  end

  test "purges every version under the tenant-bound key and records verified completion", %{
    agent: agent
  } do
    attachment = abandoned_attachment("a")

    Agent.update(agent, fn _state ->
      %{
        purge: [
          {:ok, %{deleted_versions: 2, deleted_markers: 1, verified_empty?: true}}
        ]
      }
    end)

    assert :ok = AttachmentAbandonWorker.perform(job(attachment))

    assert_receive {:purge_abandoned_attachment, %{tenant_id: tenant_id, object_key: object_key}}

    assert tenant_id == attachment.tenant_id
    assert object_key == attachment.object_key

    completed = Repo.get!(Attachment, attachment.id)
    assert completed.cleanup_status == :complete
    assert completed.cleanup_attempts == 1
    assert %DateTime{} = completed.cleanup_completed_at
  end

  test "records provider failure and retries the same key until verified empty", %{agent: agent} do
    attachment = abandoned_attachment("b")

    Agent.update(agent, fn _state ->
      %{
        purge: [
          {:error, {:object_storage_status, 503}},
          {:ok, %{deleted_versions: 1, deleted_markers: 0, verified_empty?: true}}
        ]
      }
    end)

    assert {:error, {:object_storage_status, 503}} =
             AttachmentAbandonWorker.perform(job(attachment))

    retryable = Repo.get!(Attachment, attachment.id)
    assert retryable.cleanup_status == :retryable
    assert retryable.cleanup_attempts == 1
    assert retryable.cleanup_last_error == "object_storage_status:503"

    force_cleanup_due(attachment.id)
    assert :ok = AttachmentAbandonWorker.perform(job(attachment))

    assert_receive {:purge_abandoned_attachment, first_request}
    assert_receive {:purge_abandoned_attachment, second_request}
    assert first_request == second_request

    completed = Repo.get!(Attachment, attachment.id)
    assert completed.cleanup_status == :complete
    assert completed.cleanup_attempts == 2
  end

  test "terminal job failure stays observable and remains reconcilable", %{agent: agent} do
    attachment = abandoned_attachment("c")

    Agent.update(agent, fn _state ->
      %{purge: [{:error, :object_storage_unavailable}]}
    end)

    terminal_job = %{job(attachment) | attempt: 20, max_attempts: 20}

    assert {:error, :object_storage_unavailable} =
             AttachmentAbandonWorker.perform(terminal_job)

    failed = Repo.get!(Attachment, attachment.id)
    assert failed.cleanup_status == :failed
    assert failed.cleanup_attempts == 1
    assert failed.cleanup_last_error == "object_storage_unavailable"

    force_cleanup_due(attachment.id)
    reconciler = RuntimePorts.job_worker!(:attachment_abandon_reconciler)

    assert {:ok, %{cleanup_jobs: 1}} = Attachments.reconcile_abandon_cleanups(reconciler)
  end

  test "tenant mismatch and missing envelope fail closed before storage", %{agent: agent} do
    attachment = abandoned_attachment("d")
    Agent.update(agent, fn _state -> %{purge: []} end)

    wrong_tenant_job = %{
      job(attachment)
      | args: %{
          "attachment_id" => attachment.id,
          "tenant_id" => Ecto.UUID.generate()
        }
    }

    assert {:discard, :attachment_not_found} =
             AttachmentAbandonWorker.perform(wrong_tenant_job)

    assert {:discard, :tenant_and_attachment_id_required} =
             AttachmentAbandonWorker.perform(%Oban.Job{args: %{}})

    refute_receive {:purge_abandoned_attachment, _}
  end

  test "scheduled reconciler recovers a stale pending intent" do
    account = Fixtures.account_fixture()
    checksum = String.duplicate("e", 64)

    assert {:ok, pending} =
             Attachments.create_intent(
               %{
                 file_name: "stale-reconciler.txt",
                 content_type: "text/plain",
                 byte_size: 12,
                 checksum_sha256: checksum
               },
               Fixtures.subject(account)
             )

    stale_at =
      DateTime.utc_now() |> DateTime.add(-4_000, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(attachment in Attachment, where: attachment.id == ^pending.id),
      set: [inserted_at: stale_at, updated_at: stale_at]
    )

    assert :ok = AttachmentCleanupReconcilerWorker.perform(%Oban.Job{args: %{}})

    recovered = Repo.get!(Attachment, pending.id)
    assert recovered.status == :deleted
    assert recovered.cleanup_status == :scheduled
  end

  defp abandoned_attachment(checksum_character) do
    account = Fixtures.account_fixture()
    checksum = String.duplicate(checksum_character, 64)

    assert {:ok, pending} =
             Attachments.create_intent(
               %{
                 file_name: "worker-abandon-#{checksum_character}.txt",
                 content_type: "text/plain",
                 byte_size: 12,
                 checksum_sha256: checksum
               },
               Fixtures.subject(account)
             )

    assert {:ok, abandoned} =
             Attachments.abandon_intent(pending.id, Fixtures.subject(account))

    abandoned
  end

  defp job(attachment) do
    %Oban.Job{
      args: %{
        "attachment_id" => attachment.id,
        "tenant_id" => attachment.tenant_id
      },
      attempt: 1,
      max_attempts: 20
    }
  end

  defp force_cleanup_due(attachment_id) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(attachment in Attachment, where: attachment.id == ^attachment_id),
      set: [upload_expires_at: nil, cleanup_next_attempt_at: past, updated_at: past]
    )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
