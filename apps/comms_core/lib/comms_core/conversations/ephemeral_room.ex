defmodule CommsCore.Conversations.EphemeralRoom do
  @moduledoc false

  use CommsCore.Schema

  schema "conversation_ephemeral_rooms" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    belongs_to(:guest_link, CommsCore.Conversations.GuestLink)
    field(:creator_user_id, Ecto.UUID)
    field(:creator_session_id, Ecto.UUID)
    field(:owner_kind, Ecto.Enum, values: [:guest, :registered])
    field(:status, Ecto.Enum, values: [:active, :idle, :expired], default: :active)
    field(:idempotency_digest, :binary, redact: true)
    field(:request_fingerprint, :binary, redact: true)
    field(:replay_ciphertext, :binary, redact: true)
    field(:replay_nonce, :binary, redact: true)
    field(:replay_tag, :binary, redact: true)
    field(:replay_key_id, :string, redact: true)
    field(:replay_erased_at, :utc_datetime_usec)
    field(:idempotency_expires_at, :utc_datetime_usec)
    field(:generation, :integer, default: 1)
    field(:participant_limit, :integer)
    field(:reconnect_grace_seconds, :integer)
    field(:idle_ttl_seconds, :integer)
    field(:authority_expires_at, :utc_datetime_usec)
    field(:last_presence_at, :utc_datetime_usec)
    field(:idle_since, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:expired_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :guest_link_id,
      :creator_user_id,
      :creator_session_id,
      :owner_kind,
      :status,
      :idempotency_digest,
      :request_fingerprint,
      :replay_ciphertext,
      :replay_nonce,
      :replay_tag,
      :replay_key_id,
      :replay_erased_at,
      :idempotency_expires_at,
      :generation,
      :participant_limit,
      :reconnect_grace_seconds,
      :idle_ttl_seconds,
      :authority_expires_at,
      :last_presence_at,
      :idle_since,
      :expires_at,
      :expired_at,
      :lock_version
    ])
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :guest_link_id,
      :creator_user_id,
      :creator_session_id,
      :owner_kind,
      :status,
      :idempotency_digest,
      :request_fingerprint,
      :idempotency_expires_at,
      :generation,
      :participant_limit,
      :reconnect_grace_seconds,
      :idle_ttl_seconds,
      :authority_expires_at
    ])
    |> validate_digest(:idempotency_digest)
    |> validate_digest(:request_fingerprint)
    |> validate_replay_material()
    |> validate_number(:generation, greater_than_or_equal_to: 1)
    |> validate_number(:participant_limit, greater_than_or_equal_to: 2, less_than_or_equal_to: 25)
    |> validate_number(:reconnect_grace_seconds,
      greater_than_or_equal_to: 3,
      less_than_or_equal_to: 300
    )
    |> validate_number(:idle_ttl_seconds,
      greater_than_or_equal_to: 60,
      less_than_or_equal_to: 86_400
    )
    |> unique_constraint(:conversation_id)
    |> unique_constraint(:guest_link_id)
    |> unique_constraint([:tenant_id, :idempotency_digest],
      name: :conversation_ephemeral_rooms_tenant_idempotency_unique
    )
    |> check_constraint(:owner_kind, name: :conversation_ephemeral_rooms_owner_kind_check)
    |> check_constraint(:status, name: :conversation_ephemeral_rooms_status_check)
    |> check_constraint(:idempotency_digest, name: :conversation_ephemeral_rooms_digest_check)
    |> check_constraint(:idempotency_expires_at,
      name: :conversation_ephemeral_rooms_idempotency_expiry_check
    )
    |> check_constraint(:generation, name: :conversation_ephemeral_rooms_generation_check)
    |> check_constraint(:participant_limit, name: :conversation_ephemeral_rooms_policy_check)
    |> check_constraint(:status, name: :conversation_ephemeral_rooms_state_check)
  end

  defp validate_digest(changeset, field) do
    validate_change(changeset, field, fn ^field, digest ->
      if is_binary(digest) and byte_size(digest) == 32,
        do: [],
        else: [{field, "must be a 32-byte digest"}]
    end)
  end

  defp validate_replay_material(changeset) do
    values = {
      get_field(changeset, :replay_ciphertext),
      get_field(changeset, :replay_nonce),
      get_field(changeset, :replay_tag),
      get_field(changeset, :replay_key_id),
      get_field(changeset, :replay_erased_at)
    }

    case values do
      {ciphertext, nonce, tag, key_id, nil}
      when is_binary(ciphertext) and byte_size(ciphertext) > 0 and is_binary(nonce) and
             byte_size(nonce) == 12 and is_binary(tag) and byte_size(tag) == 16 and
             is_binary(key_id) and byte_size(key_id) in 1..64 ->
        changeset

      {nil, nil, nil, nil, %DateTime{} = erased_at}
      when not is_nil(changeset.data.id) ->
        case get_field(changeset, :idempotency_expires_at) do
          %DateTime{} = expires_at ->
            if DateTime.compare(erased_at, expires_at) in [:eq, :gt],
              do: changeset,
              else: add_error(changeset, :replay_erased_at, "cannot precede replay expiry")

          _ ->
            add_error(changeset, :idempotency_expires_at, "is required")
        end

      _ ->
        add_error(
          changeset,
          :replay_ciphertext,
          "must be complete encrypted replay material or an expired erased capsule"
        )
    end
  end
end
