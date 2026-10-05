defmodule CommsCore.Accounts.MatrixEligibilityReceipt do
  @moduledoc "Durable local room fence receipt; remote bans and client-key cleanup remain pending."
  @enforce_keys [:fenced_rooms]
  defstruct [:fenced_rooms]
  @type t :: %__MODULE__{fenced_rooms: non_neg_integer()}
end
