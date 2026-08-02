defmodule CommsCore.Messaging.ActivityView do
  @moduledoc "Durable messaging activity projection."

  @enforce_keys [
    :id,
    :conversation_id,
    :actor_user_id,
    :kind,
    :sequence,
    :occurred_at
  ]
  defstruct @enforce_keys
end
