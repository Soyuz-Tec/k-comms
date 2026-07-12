defmodule CommsCore.Accounts.User do
  use CommsCore.Schema

  schema "users" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    field(:external_subject, :string)
    field(:display_name, :string)
    field(:email, :string)
    field(:password_hash, :string, redact: true)
    field(:role, Ecto.Enum, values: [:member, :admin, :owner], default: :member)
    field(:status, Ecto.Enum, values: [:active, :suspended, :deleted], default: :active)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :external_subject,
      :display_name,
      :email,
      :password_hash,
      :role,
      :status
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([
      :tenant_id,
      :external_subject,
      :display_name,
      :email,
      :role,
      :status
    ])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_length(:display_name, min: 1, max: 120)
    |> unique_constraint([:tenant_id, :external_subject])
    |> unique_constraint(:email, name: :users_tenant_email_unique)
  end

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(value), do: value
end
