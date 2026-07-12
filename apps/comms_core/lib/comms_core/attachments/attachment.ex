defmodule CommsCore.Attachments.Attachment do
  use CommsCore.Schema

  schema "attachments" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:owner_user, CommsCore.Accounts.User)
    belongs_to(:message, CommsCore.Messaging.Message)
    field(:object_key, :string)
    field(:file_name, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:checksum_sha256, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :ready, :quarantined, :deleted],
      default: :pending
    )

    field(:uploaded_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :owner_user_id,
      :message_id,
      :object_key,
      :file_name,
      :content_type,
      :byte_size,
      :checksum_sha256,
      :status,
      :uploaded_at
    ])
    |> validate_required([
      :tenant_id,
      :owner_user_id,
      :object_key,
      :file_name,
      :content_type,
      :byte_size,
      :status
    ])
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: 25_000_000)
    |> validate_length(:file_name, min: 1, max: 255)
    |> validate_length(:content_type, min: 1, max: 120)
    |> unique_constraint(:object_key)
  end
end
