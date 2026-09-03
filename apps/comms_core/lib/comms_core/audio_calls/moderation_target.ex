defmodule CommsCore.AudioCalls.ModerationTarget do
  @moduledoc "Short-lived provider moderation command material for the web adapter."

  @derive {Inspect, except: [:provider_room, :provider_identity]}
  @enforce_keys [:call_id, :participant_id, :user_id, :provider_room, :provider_identity]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end
