defmodule CommsCore.Accounts.UserView do
  @moduledoc "Stable identity projection for adapter-facing reads."

  @enforce_keys [:id, :tenant_id, :display_name, :account_type, :role, :status, :version]
  defstruct [
    :id,
    :tenant_id,
    :display_name,
    :email,
    :account_type,
    :role,
    :status,
    :version,
    :platform_role,
    :platform_role_expires_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          display_name: String.t(),
          email: String.t() | nil,
          account_type: atom(),
          role: atom(),
          status: atom(),
          version: pos_integer(),
          platform_role: atom() | nil,
          platform_role_expires_at: DateTime.t() | nil
        }
end
