defmodule CommsCore.Accounts.MemberContactView do
  @moduledoc "Current minimal contact identity in a private member workspace."
  @enforce_keys [:id, :display_name]
  defstruct [:id, :display_name]

  @type t :: %__MODULE__{id: Ecto.UUID.t(), display_name: String.t()}
end
