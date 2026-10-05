defmodule CommsCore.Accounts.FederatedIdentity do
  @moduledoc false
  use CommsCore.Schema

  schema "federated_identities" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:issuer, :string)
    field(:subject, :string)
    timestamps()
  end
end
