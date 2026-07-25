defmodule CommsCore.Conversations.EphemeralJoinReceipt do
  @moduledoc false

  use CommsCore.Schema

  schema "conversation_ephemeral_join_receipts" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:ephemeral_room, CommsCore.Conversations.EphemeralRoom)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    field(:user_id, Ecto.UUID)
    belongs_to(:membership, CommsCore.Conversations.Membership)
    field(:idempotency_digest, :binary, redact: true)
    field(:request_fingerprint, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :ephemeral_room_id,
      :conversation_id,
      :user_id,
      :membership_id,
      :idempotency_digest,
      :request_fingerprint,
      :expires_at
    ])
    |> validate_required([
      :tenant_id,
      :ephemeral_room_id,
      :conversation_id,
      :user_id,
      :membership_id,
      :idempotency_digest,
      :request_fingerprint,
      :expires_at
    ])
    |> validate_digest(:idempotency_digest)
    |> validate_digest(:request_fingerprint)
    |> unique_constraint([:ephemeral_room_id, :idempotency_digest],
      name: :conversation_ephemeral_join_receipts_room_idempotency_unique
    )
    |> check_constraint(:idempotency_digest,
      name: :conversation_ephemeral_join_receipts_digest_check
    )
    |> check_constraint(:expires_at, name: :conversation_ephemeral_join_receipts_expiry_check)
  end

  defp validate_digest(changeset, field) do
    validate_change(changeset, field, fn ^field, digest ->
      if is_binary(digest) and byte_size(digest) == 32,
        do: [],
        else: [{field, "must be a 32-byte digest"}]
    end)
  end
end
