defmodule CommsCore.Accounts.MatrixEligibilityCommand do
  @moduledoc "IdentityAccess-owned withdrawal contribution after canonical sorted User locks. No Governance or provider callback may occur."
  @enforce_keys [:tenant_id, :user_id, :timestamp]
  defstruct [:tenant_id, :user_id, :timestamp]
  @type t :: %__MODULE__{tenant_id: String.t(), user_id: String.t(), timestamp: DateTime.t()}
end
