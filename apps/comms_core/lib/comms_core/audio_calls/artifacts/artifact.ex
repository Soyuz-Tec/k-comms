defmodule CommsCore.AudioCalls.Artifacts.Artifact do
  @moduledoc false
  use CommsCore.Schema

  schema "call_artifacts" do
    field(:tenant_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:call_id, :binary_id)
    field(:meeting_id, :binary_id)
    field(:source_artifact_id, :binary_id)
    field(:transcript_language, :string)
    field(:summary_requested, :boolean, default: false)
    field(:summary_source_sha256, :string)
    field(:summary_provider_claimed_at, :utc_datetime_usec)
    field(:summary_claim_fingerprint, :string)
    field(:summary_effect_started_at, :utc_datetime_usec)
    field(:recognition_provider_id, :string)
    field(:recognition_model_sha256, :string)
    field(:recognition_source_sha256, :string)
    field(:requested_by_user_id, :binary_id)
    field(:requested_by_device_id, :binary_id)
    field(:requested_by_session_id, :binary_id)
    field(:kind, Ecto.Enum, values: [:recording, :transcript, :summary], default: :recording)

    field(:status, Ecto.Enum,
      values: [
        :pending_consent,
        :starting,
        :recording,
        :stopping,
        :processing,
        :available,
        :failed,
        :deleting,
        :deleted
      ],
      default: :pending_consent
    )

    field(:provider_room, :string)
    field(:provider_job_id, :string)
    field(:provider_start_claimed_at, :utc_datetime_usec)
    field(:last_reconciled_at, :utc_datetime_usec)
    field(:erasure_requested_at, :utc_datetime_usec)
    field(:object_key, :string)
    field(:object_version_id, :string)
    field(:object_etag, :string)
    field(:checksum_sha256, :string)
    field(:byte_size, :integer)
    field(:content_type, :string, default: "video/mp4")
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    field(:failure_code, :string)
    field(:idempotency_key, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :call_id,
      :meeting_id,
      :source_artifact_id,
      :transcript_language,
      :summary_requested,
      :summary_source_sha256,
      :summary_provider_claimed_at,
      :summary_claim_fingerprint,
      :summary_effect_started_at,
      :recognition_provider_id,
      :recognition_model_sha256,
      :recognition_source_sha256,
      :requested_by_user_id,
      :requested_by_device_id,
      :requested_by_session_id,
      :kind,
      :status,
      :provider_room,
      :provider_job_id,
      :provider_start_claimed_at,
      :last_reconciled_at,
      :erasure_requested_at,
      :object_key,
      :object_version_id,
      :object_etag,
      :checksum_sha256,
      :byte_size,
      :content_type,
      :started_at,
      :ended_at,
      :expires_at,
      :deleted_at,
      :failure_code,
      :idempotency_key
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :call_id,
      :requested_by_user_id,
      :kind,
      :status,
      :provider_room,
      :object_key,
      :content_type,
      :expires_at,
      :idempotency_key
    ])
    |> validate_length(:idempotency_key, min: 8, max: 120)
    |> validate_length(:failure_code, max: 80)
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: 10_737_418_240)
    |> unique_constraint([:tenant_id, :call_id, :idempotency_key])
    |> unique_constraint([:tenant_id, :provider_job_id])
    |> unique_constraint(:call_id, name: :call_artifacts_one_capture_per_call)
    |> unique_constraint(:source_artifact_id, name: :call_artifacts_one_transcript_per_recording)
    |> unique_constraint(:source_artifact_id, name: :call_artifacts_one_summary_per_transcript)
  end
end
