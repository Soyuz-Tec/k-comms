defmodule CommsCore.Administration.TenantView do
  @moduledoc "Stable tenant projection owned by TenantAdministration."
  defstruct [:id, :name, :slug, :status]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          slug: String.t(),
          status: :active | :suspended | :deleting
        }
end
