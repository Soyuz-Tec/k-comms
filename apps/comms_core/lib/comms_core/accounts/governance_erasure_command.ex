defmodule CommsCore.Accounts.GovernanceErasureCommand do
  @moduledoc "Persistence-neutral command for caller-owned governed user erasure."

  @enforce_keys [:tenant_id, :user_id, :pending_deletion_user_ids, :timestamp]
  defstruct [:tenant_id, :user_id, :pending_deletion_user_ids, :timestamp]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          pending_deletion_user_ids: [Ecto.UUID.t()],
          timestamp: DateTime.t()
        }
end
