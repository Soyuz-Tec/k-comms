defmodule CommsCore.Administration.InvitationIdentityAuthorization do
  @moduledoc """
  Persistence-free authorization request for an invitation's identity effects.

  TenantAdministration owns this contract. The configured IdentityAccess
  provider decides whether the actor may assign the requested identity role
  and whether the email conflicts with an identity category reserved by the
  provider.
  """

  @enforce_keys [:tenant_id, :actor_user_id, :email, :role]
  defstruct [:tenant_id, :actor_user_id, :email, :role]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t(),
          email: String.t(),
          role: atom()
        }
end
