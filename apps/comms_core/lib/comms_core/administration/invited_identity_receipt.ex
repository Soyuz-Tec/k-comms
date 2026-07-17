defmodule CommsCore.Administration.InvitedIdentityReceipt do
  @moduledoc """
  TenantAdministration-owned result of enrolling an invited human identity.

  This is an Ecto-free use-case receipt, not an IdentityAccess persistence
  model. Its fields are limited to the accepted-invitation response and the
  identifiers TenantAdministration must persist.
  """

  @enforce_keys [
    :id,
    :tenant_id,
    :display_name,
    :email,
    :account_type,
    :role,
    :status,
    :version
  ]
  defstruct [
    :id,
    :tenant_id,
    :display_name,
    :email,
    :account_type,
    :role,
    :status,
    :version
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          display_name: String.t(),
          email: String.t(),
          account_type: :human,
          role: atom(),
          status: :active,
          version: pos_integer()
        }
end
