defmodule CommsCore.AudioCalls.EvictionClaim do
  @moduledoc "Ecto-free claim consumed by the participant-eviction worker."

  alias CommsCore.AudioCalls.ProviderCall

  @enforce_keys [:participant_id, :provider_call, :provider_identity, :enforce_until]
  defstruct [:participant_id, :provider_call, :provider_identity, :enforce_until]

  @type t :: %__MODULE__{
          participant_id: String.t(),
          provider_call: ProviderCall.t(),
          provider_identity: String.t(),
          enforce_until: DateTime.t()
        }
end
