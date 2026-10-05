defmodule CommsCore.Accounts.DirectoryUsersLockQuery do
  @moduledoc """
  Exact workspace identities to retain inside a caller-owned transaction.

  The absolute monotonic deadline covers the caller's preceding admission wait
  and the identity locks. This contract grants no membership or account role.
  """

  @enforce_keys [:tenant_id, :user_ids, :deadline]
  defstruct [:tenant_id, :user_ids, :deadline]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          user_ids: [Ecto.UUID.t()],
          deadline: integer()
        }
end
