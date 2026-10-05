defmodule CommsCore.Accounts.LockedDirectoryUser do
  @moduledoc "Current eligible workspace identity retained by IdentityAccess."

  @enforce_keys [:id, :tenant_id, :account_type]
  defstruct [:id, :tenant_id, :account_type]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          account_type: :human | :service
        }
end
