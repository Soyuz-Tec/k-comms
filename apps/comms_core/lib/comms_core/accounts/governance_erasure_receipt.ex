defmodule CommsCore.Accounts.GovernanceErasureReceipt do
  @moduledoc "Identifiers from a transaction-scoped governed identity contribution."

  @enforce_keys [:user_id, :revoked_session_ids]
  defstruct [:user_id, :revoked_session_ids]

  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t(),
          revoked_session_ids: [Ecto.UUID.t()]
        }
end
