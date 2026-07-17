defmodule CommsCore.Administration.AuthorizationActor do
  @moduledoc """
  Verified identity used by TenantAdministration to attribute an authorization denial.
  """

  @enforce_keys [:tenant_id, :user_id]
  defstruct [:tenant_id, :user_id, :request_id]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          request_id: String.t() | nil
        }
end
