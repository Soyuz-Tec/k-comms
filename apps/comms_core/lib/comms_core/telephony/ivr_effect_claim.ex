defmodule CommsCore.Telephony.IvrEffectClaim do
  @moduledoc "Once-issued worker claim. Durable consumption precedes a forward PBX effect."
  @enforce_keys [:run_id, :step, :action, :nonce]
  defstruct [:run_id, :step, :action, :nonce]

  @type t :: %__MODULE__{
          run_id: String.t(),
          step: pos_integer(),
          action: :play | :destination | :connect_destination,
          nonce: String.t()
        }
end
