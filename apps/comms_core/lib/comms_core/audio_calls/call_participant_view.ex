defmodule CommsCore.AudioCalls.CallParticipantView do
  @moduledoc "Authorized, provider-neutral call participant state."

  @enforce_keys [:id, :user_id, :status, :hand_raised]
  defstruct [:id, :user_id, :status, :hand_raised, :hand_raised_at]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          status: atom(),
          hand_raised: boolean(),
          hand_raised_at: DateTime.t() | nil
        }
end
