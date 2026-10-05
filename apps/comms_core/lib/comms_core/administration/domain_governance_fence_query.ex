defmodule CommsCore.Administration.DomainGovernanceFenceQuery do
  @moduledoc "The exact tenant fence needed before personal DNS challenge effects."
  @enforce_keys [:tenant_id, :deadline]
  defstruct [:tenant_id, :deadline]
  @type t :: %__MODULE__{tenant_id: Ecto.UUID.t(), deadline: integer()}
end
