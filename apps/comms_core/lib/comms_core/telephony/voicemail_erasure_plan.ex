defmodule CommsCore.Telephony.VoicemailErasurePlan do
  @moduledoc "Owner projection of durable voicemail erasure still awaiting verified physical purge."
  @enforce_keys [:pending_voicemail_count]
  defstruct [:pending_voicemail_count]
  @type t :: %__MODULE__{pending_voicemail_count: non_neg_integer()}
end
