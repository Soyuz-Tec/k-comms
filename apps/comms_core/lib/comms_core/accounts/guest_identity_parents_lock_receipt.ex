defmodule CommsCore.Accounts.GuestIdentityParentsLockReceipt do
  @moduledoc "Retained parent IDs; this receipt grants no identity or conversation access."

  @enforce_keys [:tenant_id, :user_ids]
  defstruct [:tenant_id, :user_ids]

  @type t :: %__MODULE__{tenant_id: Ecto.UUID.t(), user_ids: [Ecto.UUID.t()]}
end
