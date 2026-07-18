defmodule CommsCore.Administration.CallLifecycleReceipt do
  @moduledoc """
  Persistence-neutral receipt for a tenant call-lifecycle contribution.
  """

  @enforce_keys [:revoked_participant_count]
  defstruct [:revoked_participant_count]

  @type t :: %__MODULE__{revoked_participant_count: non_neg_integer()}
end
