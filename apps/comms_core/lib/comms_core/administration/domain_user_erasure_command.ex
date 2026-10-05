defmodule CommsCore.Administration.DomainUserErasureCommand do
  @moduledoc "Owner-coordinated removal of one user's personal DNS challenges."
  @enforce_keys [:tenant_id, :user_id, :timestamp]
  defstruct [:tenant_id, :user_id, :timestamp]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          timestamp: DateTime.t()
        }
end
