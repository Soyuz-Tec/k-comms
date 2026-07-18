defmodule CommsCore.Administration.Invitation do
  use CommsCore.Schema

  schema "invitations" do
    field(:tenant_id, :binary_id)
    field(:invited_by_user_id, :binary_id)
    field(:accepted_user_id, :binary_id)
    field(:email, :string)

    field(:role, Ecto.Enum,
      values: [:member, :moderator, :admin, :compliance_admin, :security_admin],
      default: :member
    )

    field(:token_hash, :binary, redact: true)

    field(:status, Ecto.Enum,
      values: [:pending, :accepted, :revoked, :expired],
      default: :pending
    )

    field(:expires_at, :utc_datetime_usec)
    field(:accepted_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :tenant_id,
      :invited_by_user_id,
      :accepted_user_id,
      :email,
      :role,
      :token_hash,
      :status,
      :expires_at,
      :accepted_at,
      :revoked_at,
      :idempotency_key
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([
      :tenant_id,
      :invited_by_user_id,
      :email,
      :role,
      :token_hash,
      :status,
      :expires_at
    ])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_length(:idempotency_key, max: 200)
    |> unique_constraint([:tenant_id, :idempotency_key])
    |> unique_constraint(:email, name: :invitations_tenant_pending_email_unique)
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(email), do: email
end
