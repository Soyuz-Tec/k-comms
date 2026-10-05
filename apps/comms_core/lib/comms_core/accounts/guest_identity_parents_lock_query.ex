defmodule CommsCore.Accounts.GuestIdentityParentsLockQuery do
  @moduledoc "Exact identity parents retained before guest lifecycle resources."

  @enforce_keys [:tenant_id, :user_ids, :deadline, :require_active_tenant]
  defstruct [:tenant_id, :user_ids, :deadline, :require_active_tenant]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_ids: [Ecto.UUID.t()],
          deadline: integer(),
          require_active_tenant: boolean()
        }
end
