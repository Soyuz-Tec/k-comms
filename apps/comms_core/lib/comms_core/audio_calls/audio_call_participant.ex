defmodule CommsCore.AudioCalls.AudioCallParticipant do
  use CommsCore.Schema

  schema "audio_call_participants" do
    field(:tenant_id, :binary_id)
    belongs_to(:audio_call, CommsCore.AudioCalls.AudioCall)
    field(:conversation_id, :binary_id)
    field(:user_id, :binary_id)
    field(:device_id, :binary_id)
    field(:session_id, :binary_id)
    field(:provider_identity, :string)
    field(:status, Ecto.Enum, values: [:admitted, :revoked, :evicted], default: :admitted)
    field(:admitted_at, :utc_datetime_usec)
    field(:credential_issued_at, :utc_datetime_usec)
    field(:credential_issue_count, :integer, default: 0)
    field(:revoked_at, :utc_datetime_usec)
    field(:revocation_reason, :string)

    field(:eviction_status, Ecto.Enum,
      values: [:not_required, :pending, :enforcing, :completed],
      default: :not_required
    )

    field(:eviction_enforce_until, :utc_datetime_usec)
    field(:last_eviction_attempt_at, :utc_datetime_usec)
    field(:last_eviction_success_at, :utc_datetime_usec)
    field(:evicted_at, :utc_datetime_usec)
    field(:eviction_attempts, :integer, default: 0)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def admission_changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :tenant_id,
      :audio_call_id,
      :conversation_id,
      :user_id,
      :device_id,
      :session_id,
      :provider_identity,
      :status,
      :admitted_at,
      :credential_issued_at,
      :credential_issue_count,
      :revoked_at,
      :revocation_reason,
      :eviction_status,
      :eviction_enforce_until,
      :last_eviction_attempt_at,
      :last_eviction_success_at,
      :evicted_at,
      :eviction_attempts,
      :lock_version
    ])
    |> validate_required([
      :tenant_id,
      :audio_call_id,
      :conversation_id,
      :user_id,
      :device_id,
      :session_id,
      :provider_identity,
      :status,
      :admitted_at,
      :credential_issue_count,
      :eviction_status,
      :eviction_attempts
    ])
    |> validate_length(:provider_identity, min: 16, max: 200)
    |> validate_length(:revocation_reason, min: 3, max: 120)
    |> validate_number(:credential_issue_count, greater_than_or_equal_to: 0)
    |> validate_number(:eviction_attempts, greater_than_or_equal_to: 0)
    |> unique_constraint([:audio_call_id, :session_id],
      name: :audio_call_participants_one_admission_per_call_session
    )
    |> unique_constraint([:tenant_id, :provider_identity],
      name: :audio_call_participants_provider_identity_unique
    )
    |> check_constraint(:status, name: :audio_call_participants_valid_status)
    |> check_constraint(:eviction_status,
      name: :audio_call_participants_valid_eviction_status
    )
    |> check_constraint(:credential_issue_count,
      name: :audio_call_participants_issue_count_nonnegative
    )
    |> check_constraint(:status, name: :audio_call_participants_state_consistent)
  end
end
