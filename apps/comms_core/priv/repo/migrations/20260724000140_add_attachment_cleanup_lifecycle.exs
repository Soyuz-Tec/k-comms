defmodule CommsCore.Repo.Migrations.AddAttachmentCleanupLifecycle do
  use Ecto.Migration

  def up do
    alter table(:attachments) do
      add(:upload_expires_at, :utc_datetime_usec)
      add(:cleanup_status, :text, null: false, default: "not_required")
      add(:cleanup_attempts, :integer, null: false, default: 0)
      add(:cleanup_next_attempt_at, :utc_datetime_usec)
      add(:cleanup_claimed_at, :utc_datetime_usec)
      add(:cleanup_last_error, :text)
      add(:cleanup_completed_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE attachments
    SET cleanup_status = 'scheduled',
        cleanup_next_attempt_at = NOW()
    WHERE status = 'deleted'
      AND message_id IS NULL
    """)

    create(
      constraint(:attachments, :attachments_cleanup_status_allowed,
        check:
          "cleanup_status IN ('not_required', 'scheduled', 'running', 'retryable', 'failed', 'complete')"
      )
    )

    create(
      constraint(:attachments, :attachments_cleanup_attempts_non_negative,
        check: "cleanup_attempts >= 0"
      )
    )

    create(
      constraint(:attachments, :attachments_cleanup_claim_consistent,
        check:
          "(cleanup_status = 'running' AND cleanup_claimed_at IS NOT NULL) OR (cleanup_status <> 'running' AND cleanup_claimed_at IS NULL)"
      )
    )

    create(
      constraint(:attachments, :attachments_cleanup_completion_consistent,
        check:
          "(cleanup_status = 'complete' AND cleanup_completed_at IS NOT NULL) OR (cleanup_status <> 'complete' AND cleanup_completed_at IS NULL)"
      )
    )

    create(
      index(:attachments, [:cleanup_status, :cleanup_next_attempt_at],
        name: :attachments_cleanup_due_index,
        where: "status = 'deleted' AND message_id IS NULL AND cleanup_status <> 'complete'"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:attachments, [:cleanup_status, :cleanup_next_attempt_at],
        name: :attachments_cleanup_due_index
      )
    )

    drop(constraint(:attachments, :attachments_cleanup_completion_consistent))
    drop(constraint(:attachments, :attachments_cleanup_claim_consistent))
    drop(constraint(:attachments, :attachments_cleanup_attempts_non_negative))
    drop(constraint(:attachments, :attachments_cleanup_status_allowed))

    alter table(:attachments) do
      remove(:cleanup_completed_at)
      remove(:cleanup_last_error)
      remove(:cleanup_claimed_at)
      remove(:cleanup_next_attempt_at)
      remove(:cleanup_attempts)
      remove(:cleanup_status)
      remove(:upload_expires_at)
    end
  end
end
