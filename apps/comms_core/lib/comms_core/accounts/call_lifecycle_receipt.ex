defmodule CommsCore.Accounts.CallLifecycleReceipt do
  @moduledoc """
  Persistence-neutral receipt for an IdentityAccess call-lifecycle contribution.
  """

  @enforce_keys [:revoked_participant_count]
  defstruct [:revoked_participant_count]

  @type t :: %__MODULE__{revoked_participant_count: non_neg_integer()}
end
