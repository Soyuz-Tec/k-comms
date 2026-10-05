defmodule CommsCore.Repo.Migrations.AddCallArtifacts do
  use Ecto.Migration

  def change do
    create table(:call_artifacts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false)

      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:call_id, references(:audio_calls, type: :uuid, on_delete: :restrict), null: false)
      add(:meeting_id, :uuid)
      add(:source_artifact_id, :uuid)
      add(:transcript_language, :text)
      add(:requested_by_user_id, :uuid, null: false)
      add(:kind, :text, null: false, default: "recording")
      add(:status, :text, null: false, default: "pending_consent")
      add(:provider_room, :text, null: false)
      add(:provider_job_id, :text)
      add(:provider_start_claimed_at, :utc_datetime_usec)
      add(:last_reconciled_at, :utc_datetime_usec)
      add(:object_key, :text, null: false)
      add(:object_version_id, :text)
      add(:object_etag, :text)
      add(:checksum_sha256, :text)
      add(:byte_size, :bigint)
      add(:content_type, :text, null: false)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:deleted_at, :utc_datetime_usec)
      add(:failure_code, :text)
      add(:idempotency_key, :text, null: false)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:call_artifacts, [:tenant_id, :call_id, :idempotency_key]))

    create(
      unique_index(:call_artifacts, [:tenant_id, :provider_job_id],
        where: "provider_job_id IS NOT NULL"
      )
    )

    create(
      unique_index(:call_artifacts, [:call_id],
        name: :call_artifacts_one_capture_per_call,
        where: "status IN ('pending_consent','starting','recording','stopping')"
      )
    )

    create(index(:call_artifacts, [:tenant_id, :conversation_id, :inserted_at]))
    create(index(:call_artifacts, [:expires_at], where: "status != 'deleted'"))

    create(
      constraint(:call_artifacts, :call_artifacts_valid_state,
        check:
          "status IN ('pending_consent','starting','recording','stopping','processing','available','failed','deleting','deleted')"
      )
    )

    create(
      constraint(:call_artifacts, :call_artifacts_valid_kind,
        check: "kind IN ('recording','transcript')"
      )
    )

    create(
      constraint(:call_artifacts, :call_artifacts_ready_identity,
        check:
          "status != 'available' OR (kind = 'transcript' AND source_artifact_id IS NOT NULL) OR (object_version_id IS NOT NULL AND checksum_sha256 IS NOT NULL AND byte_size > 0 AND object_etag IS NOT NULL)"
      )
    )

    create(
      unique_index(:call_artifacts, [:source_artifact_id],
        where: "kind = 'transcript' AND status NOT IN ('deleted','failed')",
        name: :call_artifacts_one_transcript_per_recording
      )
    )

    create table(:call_artifact_consents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :uuid, null: false)

      add(:artifact_id, references(:call_artifacts, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :participant_id,
        references(:audio_call_participants, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:user_id, :uuid, null: false)
      add(:session_id, :uuid, null: false)
      add(:accepted, :boolean, null: false, default: false)
      add(:policy_version, :text, null: false, default: "meeting-artifacts-v1")
      add(:decided_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:call_artifact_consents, [:artifact_id, :participant_id]))

    create table(:call_artifact_provider_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :uuid, null: false)

      add(:artifact_id, references(:call_artifacts, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:event_id, :text, null: false)
      add(:body_sha256, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:call_artifact_provider_events, [:event_id]))

    create table(:call_artifact_segments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :uuid, null: false)

      add(:artifact_id, references(:call_artifacts, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:sequence, :integer, null: false)
      add(:start_ms, :integer, null: false)
      add(:end_ms, :integer, null: false)
      add(:text, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:call_artifact_segments, [:artifact_id, :sequence]))

    create(
      constraint(:call_artifact_segments, :call_artifact_segments_bounds,
        check:
          "sequence >= 0 AND sequence < 10000 AND start_ms >= 0 AND end_ms >= start_ms AND end_ms <= 28800000 AND octet_length(text) BETWEEN 1 AND 8000"
      )
    )
  end
end
