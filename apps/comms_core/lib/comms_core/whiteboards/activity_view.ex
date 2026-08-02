defmodule CommsCore.Whiteboards.ActivityView do
  @moduledoc "Durable whiteboard activity projection."

  @enforce_keys [:id, :conversation_id, :actor_user_id, :kind, :sequence, :occurred_at]
  defstruct @enforce_keys
end
