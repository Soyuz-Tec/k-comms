defmodule CommsCore.Accounts.MatrixAccessProtection do
  @enforce_keys [:capture_blocked]
  defstruct [:capture_blocked]
  @type t :: %__MODULE__{capture_blocked: boolean()}
end
