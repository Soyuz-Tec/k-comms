defmodule CommsCore.Accounts.UserView do
  @moduledoc "Stable identity projection for adapter-facing reads."

  @enforce_keys [
    :id,
    :tenant_id,
    :display_name,
    :account_type,
    :access_scope,
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
    :access_scope,
    :guest_expires_at,
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
          access_scope: :workspace | :conversation_only,
          guest_expires_at: DateTime.t() | nil,
          role: atom(),
          status: atom(),
          version: pos_integer(),
          platform_role: atom() | nil,
          platform_role_expires_at: DateTime.t() | nil
        }
end
