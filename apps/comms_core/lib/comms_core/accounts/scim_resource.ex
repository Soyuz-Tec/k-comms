defmodule CommsCore.Accounts.ScimResource do
  @moduledoc false
  use CommsCore.Schema

  schema "scim_directory_resources" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:kind, :string)
    field(:external_id, :string)
    field(:display_name, :string)
    field(:members, {:array, Ecto.UUID}, default: [])
    field(:lock_version, :integer, default: 1)
    timestamps()
  end
end
