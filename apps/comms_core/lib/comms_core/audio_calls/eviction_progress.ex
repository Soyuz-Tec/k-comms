defmodule CommsCore.AudioCalls.EvictionProgress do
  @moduledoc "Ecto-free result returned after recording one provider-eviction attempt."

  @enforce_keys [:participant_id, :eviction_status]
  defstruct [:participant_id, :eviction_status]

  @type t :: %__MODULE__{
          participant_id: String.t(),
          eviction_status: :pending | :enforcing | :completed
        }
end
