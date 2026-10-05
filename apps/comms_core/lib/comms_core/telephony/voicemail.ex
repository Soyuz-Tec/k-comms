defmodule CommsCore.Telephony.Voicemail do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_voicemails" do
    field(:tenant_id, :binary_id)
    field(:mailbox_id, :binary_id)
    field(:call_id, :binary_id)
    field(:user_id, :binary_id)
    field(:recording_name, :string)
    field(:notice_media, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :available, :failed, :deleting, :deleted],
      default: :pending
    )

    field(:duration_seconds, :integer)
    field(:retention_expires_at, :utc_datetime_usec)
    field(:available_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    field(:recording_deadline, :utc_datetime_usec)
    field(:object_key, :string)
    field(:object_version_id, :string)
    field(:object_etag, :string)
    field(:checksum_sha256, :string)
    field(:verified_checksum_sha256, :string)
    field(:byte_size, :integer)
    field(:content_type, :string, default: "audio/wav")
    field(:provider_deleted_at, :utc_datetime_usec)
    field(:protected_user_ids, {:array, :binary_id}, default: [])
    field(:erasure_requested_at, :utc_datetime_usec)
    field(:erasure_verified_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([
      :tenant_id,
      :mailbox_id,
      :call_id,
      :user_id,
      :recording_name,
      :notice_media,
      :retention_expires_at,
      :recording_deadline
    ])
    |> unique_constraint(:call_id)
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0, less_than_or_equal_to: 120)
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: 8_388_608)
    |> validate_inclusion(:content_type, ["audio/wav"])
    |> validate_format(:checksum_sha256, ~r/^[a-f0-9]{64}$/)
    |> validate_format(:verified_checksum_sha256, ~r/^[a-f0-9]{64}$/)
  end
end
