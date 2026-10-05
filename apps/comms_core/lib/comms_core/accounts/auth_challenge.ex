defmodule CommsCore.Accounts.AuthChallenge do
  @moduledoc false
  use CommsCore.Schema

  schema "identity_auth_challenges" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:kind, :string)
    field(:token_hash, :binary, redact: true)
    field(:payload, :map, default: %{}, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    timestamps()
  end
end
