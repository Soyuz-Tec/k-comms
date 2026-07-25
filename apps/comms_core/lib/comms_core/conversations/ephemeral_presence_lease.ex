defmodule CommsCore.Conversations.EphemeralPresenceLease do
  @moduledoc false

  use CommsCore.Schema

  schema "conversation_ephemeral_presence_leases" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:ephemeral_room, CommsCore.Conversations.EphemeralRoom)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    field(:user_id, Ecto.UUID)
    field(:session_id, Ecto.UUID)
    field(:connection_digest, :binary, redact: true)
    field(:opened_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :ephemeral_room_id,
      :conversation_id,
      :user_id,
      :session_id,
      :connection_digest,
      :opened_at,
      :last_seen_at,
      :expires_at,
      :closed_at,
      :lock_version
    ])
    |> validate_required([
      :tenant_id,
      :ephemeral_room_id,
      :conversation_id,
      :user_id,
      :session_id,
      :connection_digest,
      :opened_at,
      :last_seen_at,
      :expires_at
    ])
    |> validate_change(:connection_digest, fn :connection_digest, digest ->
      if is_binary(digest) and byte_size(digest) == 32,
        do: [],
        else: [connection_digest: "must be a 32-byte digest"]
    end)
    |> unique_constraint([:ephemeral_room_id, :connection_digest],
      name: :conversation_ephemeral_presence_leases_room_connection_unique
    )
    |> check_constraint(:connection_digest,
      name: :conversation_ephemeral_presence_leases_digest_check
    )
    |> check_constraint(:expires_at,
      name: :conversation_ephemeral_presence_leases_expiry_check
    )
  end
end
