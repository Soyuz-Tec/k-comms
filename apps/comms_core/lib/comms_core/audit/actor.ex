defmodule CommsCore.Audit.Actor do
  @moduledoc """
  Ecto-free identity reference for an authorization-denial audit command.

  The IdentityAccess owner facade is the canonical resolver. It returns this
  contract only after verifying that the user belongs to the claimed tenant.
  """

  @enforce_keys [:tenant_id, :user_id]
  defstruct [:tenant_id, :user_id, :request_id]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          request_id: String.t() | nil
        }
end
