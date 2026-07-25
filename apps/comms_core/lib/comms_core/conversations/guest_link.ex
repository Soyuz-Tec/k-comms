defmodule CommsCore.Conversations.GuestLink do
  @moduledoc false

  use CommsCore.Schema

  schema "conversation_guest_links" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:conversation, CommsCore.Conversations.Conversation)
    field(:created_by_user_id, Ecto.UUID)
    field(:token_digest, :binary, redact: true)
    field(:conversion_email, :string, redact: true)
    field(:conversion_verification_digest, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:max_uses, :integer)
    field(:use_count, :integer, default: 0)
    field(:revoked_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :conversation_id,
      :created_by_user_id,
      :token_digest,
      :conversion_email,
      :conversion_verification_digest,
      :expires_at,
      :max_uses,
      :use_count,
      :revoked_at,
      :lock_version
    ])
    |> update_change(:conversion_email, &normalize_email/1)
    |> validate_required([
      :tenant_id,
      :conversation_id,
      :created_by_user_id,
      :token_digest,
      :expires_at,
      :max_uses,
      :use_count
    ])
    |> validate_change(:token_digest, fn :token_digest, digest ->
      if is_binary(digest) and byte_size(digest) == 32,
        do: [],
        else: [token_digest: "must be a 32-byte digest"]
    end)
    |> validate_change(
      :conversion_verification_digest,
      fn :conversion_verification_digest, digest ->
        if is_binary(digest) and byte_size(digest) == 32,
          do: [],
          else: [conversion_verification_digest: "must be a 32-byte digest"]
      end
    )
    |> validate_format(:conversion_email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_length(:conversion_email, max: 320)
    |> validate_conversion_verification_pair()
    |> validate_number(:max_uses, greater_than_or_equal_to: 1, less_than_or_equal_to: 25)
    |> validate_number(:use_count, greater_than_or_equal_to: 0)
    |> check_constraint(:max_uses, name: :conversation_guest_links_max_uses_check)
    |> check_constraint(:use_count, name: :conversation_guest_links_use_count_check)
    |> check_constraint(:token_digest, name: :conversation_guest_links_digest_check)
    |> check_constraint(:conversion_verification_digest,
      name: :conversation_guest_links_conversion_verification_digest_check
    )
    |> check_constraint(:expires_at, name: :conversation_guest_links_expiry_check)
  end

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(value), do: value

  defp validate_conversion_verification_pair(changeset) do
    case {
      get_field(changeset, :conversion_email),
      get_field(changeset, :conversion_verification_digest)
    } do
      {nil, nil} ->
        changeset

      {email, digest}
      when is_binary(email) and is_binary(digest) and byte_size(digest) == 32 ->
        changeset

      _ ->
        add_error(
          changeset,
          :conversion_verification_digest,
          "must be a 32-byte digest exactly when account conversion is enabled"
        )
    end
  end
end
