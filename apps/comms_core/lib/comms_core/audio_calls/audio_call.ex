defmodule CommsCore.AudioCalls.AudioCall do
  use CommsCore.Schema

  schema "audio_calls" do
    belongs_to(:tenant, CommsCore.Administration.Tenant)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    belongs_to(:started_by_user, CommsCore.Accounts.User)
    belongs_to(:ended_by_user, CommsCore.Accounts.User)
    field(:provider_room, :string)
    field(:media_kind, Ecto.Enum, values: [:audio, :video], default: :audio)
    field(:status, Ecto.Enum, values: [:active, :ending, :ended], default: :active)
    field(:started_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:end_reason, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(call, attrs) do
    call
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :started_by_user_id,
      :ended_by_user_id,
      :provider_room,
      :media_kind,
      :status,
      :started_at,
      :expires_at,
      :ended_at,
      :end_reason,
      :lock_version
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :started_by_user_id,
      :provider_room,
      :media_kind,
      :status,
      :started_at,
      :expires_at
    ])
    |> validate_length(:provider_room, min: 8, max: 200)
    |> validate_length(:end_reason, min: 3, max: 120)
    |> unique_constraint([:tenant_id, :conversation_id],
      name: :audio_calls_one_active_per_conversation
    )
    |> unique_constraint([:tenant_id, :provider_room],
      name: :audio_calls_tenant_provider_room_unique
    )
    |> check_constraint(:status, name: :audio_calls_valid_status)
    |> check_constraint(:media_kind, name: :audio_calls_valid_media_kind)
    |> check_constraint(:expires_at, name: :audio_calls_bounded_expiry)
    |> check_constraint(:status, name: :audio_calls_end_state_consistent)
  end
end
