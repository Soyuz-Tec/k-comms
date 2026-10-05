defmodule CommsCore.Accounts.MatrixIdentityView do
  @moduledoc "Immutable, verified Matrix principal mapping; contains no authentication or encryption secrets."
  @enforce_keys [:tenant_id, :user_id, :issuer, :matrix_user_id, :provisioning_state]
  defstruct [:tenant_id, :user_id, :issuer, :matrix_user_id, :provisioning_state]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          user_id: String.t(),
          issuer: String.t(),
          matrix_user_id: String.t(),
          provisioning_state: :ready
        }
end
