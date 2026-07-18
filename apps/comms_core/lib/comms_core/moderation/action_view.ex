defmodule CommsCore.Moderation.ActionView do
  @moduledoc "Stable moderation-action projection."
  defstruct [
    :id,
    :moderation_case_id,
    :actor_user_id,
    :action_type,
    :note,
    :metadata,
    :inserted_at
  ]
end
