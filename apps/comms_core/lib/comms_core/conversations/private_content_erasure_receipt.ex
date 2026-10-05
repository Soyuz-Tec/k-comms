defmodule CommsCore.Conversations.PrivateContentErasureReceipt do
  @enforce_keys [:opaque_events_erased]
  defstruct [:opaque_events_erased]
  @type t :: %__MODULE__{opaque_events_erased: non_neg_integer()}
end
