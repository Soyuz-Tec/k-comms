defmodule CommsCore.AttachmentAbandonmentTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Attachments
  alias CommsCore.Attachments.Attachment
  alias CommsCore.{Repo, RuntimePorts}
  alias CommsTestSupport.Fixtures

  test "abandonment is owner-scoped, idempotent, and durably queues cleanup" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    foreign_user = Fixtures.user_fixture(account).user
    pending = pending_attachment(account, "a")

    assert {:error, :not_found} =
             Attachments.abandon_intent(
               pending.id,
               %{subject | user_id: foreign_user.id}
             )

    assert {:ok, abandoned} = Attachments.abandon_intent(pending.id, subject)
    assert abandoned.status == :deleted
    assert is_nil(abandoned.message_id)

    worker_name =
      :attachment_abandon
      |> RuntimePorts.job_worker_name!()

    assert 1 ==
             Repo.aggregate(
               from(job in Oban.Job,
                 where:
                   job.worker == ^worker_name and
                     fragment("?->>'attachment_id'", job.args) == ^pending.id
               ),
               :count
             )

    assert {:ok, repeated} = Attachments.abandon_intent(pending.id, subject)
    assert repeated.status == :deleted

    assert 1 ==
             Repo.aggregate(
               from(job in Oban.Job,
                 where:
                   job.worker == ^worker_name and
                     fragment("?->>'attachment_id'", job.args) == ^pending.id
               ),
               :count
             )

    assert {:error, :attachment_not_pending} =
             Attachments.mark_uploaded(
               pending.id,
               pending.checksum_sha256,
               identity(pending.checksum_sha256, "late"),
               subject
             )
  end

  test "cleanup waits for the upload lease, enforces tenant scope, and persists attempts" do
    account = Fixtures.account_fixture()
    pending = pending_attachment(account, "b")
    subject = Fixtures.subject(account)
    worker = RuntimePorts.job_worker!(:attachment_abandon)

    expires_at =
      DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, authorized} =
             Attachments.record_upload_authorization(pending.id, expires_at, subject)

    assert authorized.upload_expires_at == expires_at

    assert {:ok, abandoned} = Attachments.abandon_intent(pending.id, subject)
    assert abandoned.cleanup_status == :scheduled
    assert DateTime.diff(abandoned.cleanup_next_attempt_at, expires_at, :second) == 300

    assert {:error, :forbidden} =
             Attachments.claim_abandon_cleanup(account.tenant.id, pending.id, __MODULE__)

    assert {:error, :not_found} =
             Attachments.claim_abandon_cleanup(Ecto.UUID.generate(), pending.id, worker)

    assert {:snooze, seconds} =
             Attachments.claim_abandon_cleanup(account.tenant.id, pending.id, worker)

    assert seconds > 0

    force_cleanup_due(pending.id)

    assert {:ok, target} =
             Attachments.claim_abandon_cleanup(account.tenant.id, pending.id, worker)

    assert target.id == pending.id
    assert target.tenant_id == account.tenant.id
    assert target.object_key == pending.object_key

    assert {:ok, retryable} =
             Attachments.record_abandon_cleanup_failure(
               account.tenant.id,
               pending.id,
               {:object_storage_status, 503},
               false,
               worker
             )

    assert retryable.cleanup_status == :retryable
    assert retryable.cleanup_attempts == 1
    assert retryable.cleanup_last_error == "object_storage_status:503"
    assert is_nil(retryable.cleanup_claimed_at)

    force_cleanup_due(pending.id)

    assert {:ok, _target} =
             Attachments.claim_abandon_cleanup(account.tenant.id, pending.id, worker)

    assert {:ok, complete} =
             Attachments.complete_abandon_cleanup(account.tenant.id, pending.id, worker)

    assert complete.cleanup_status == :complete
    assert complete.cleanup_attempts == 2
    assert is_nil(complete.cleanup_last_error)
    assert %DateTime{} = complete.cleanup_completed_at
  end

  test "reconciler converts unreachable pending intents into tenant-bound cleanup work" do
    account = Fixtures.account_fixture()
    pending = pending_attachment(account, "c")
    reconciler = RuntimePorts.job_worker!(:attachment_abandon_reconciler)

    stale_at =
      DateTime.utc_now() |> DateTime.add(-4_000, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(attachment in Attachment, where: attachment.id == ^pending.id),
      set: [inserted_at: stale_at, updated_at: stale_at]
    )

    assert {:ok, %{stale_intents: 1, cleanup_jobs: 1}} =
             Attachments.reconcile_abandon_cleanups(reconciler)

    reconciled = Repo.get!(Attachment, pending.id)
    assert reconciled.status == :deleted
    assert reconciled.cleanup_status == :scheduled

    worker_name = RuntimePorts.job_worker_name!(:attachment_abandon)

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == ^worker_name and
                   fragment("?->>'attachment_id'", job.args) == ^pending.id and
                   fragment("?->>'tenant_id'", job.args) == ^account.tenant.id
             )
           )
  end

  defp pending_attachment(account, checksum_character) do
    checksum = String.duplicate(checksum_character, 64)

    assert {:ok, attachment} =
             Attachments.create_intent(
               %{
                 file_name: "abandon-#{checksum_character}.txt",
                 content_type: "text/plain",
                 byte_size: 12,
                 checksum_sha256: checksum
               },
               Fixtures.subject(account)
             )

    attachment
  end

  defp identity(checksum, suffix) do
    %{
      object_version_id: "version-#{suffix}",
      object_etag: "\"etag-#{suffix}\"",
      verified_checksum_sha256: checksum
    }
  end

  defp force_cleanup_due(attachment_id) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(attachment in Attachment, where: attachment.id == ^attachment_id),
      set: [upload_expires_at: nil, cleanup_next_attempt_at: past, updated_at: past]
    )
  end
end
