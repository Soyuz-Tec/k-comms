defmodule CommsCore.Accounts.MatrixParticipantsLockQuery do
  @moduledoc "Bounded IdentityAccess-owned sorted participant identity fence; retained readers receive eligible UUIDs, never persistence rows."
  @enforce_keys [:tenant_id, :user_ids, :deadline]
  defstruct [:tenant_id, :user_ids, :deadline]
  @type t :: %__MODULE__{tenant_id: String.t(), user_ids: [String.t()], deadline: integer()}
end
