defmodule CommsCore.AudioCalls.ActivityView do
  @moduledoc "Durable call lifecycle activity projection."

  @enforce_keys [:id, :conversation_id, :actor_user_id, :kind, :occurred_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end
