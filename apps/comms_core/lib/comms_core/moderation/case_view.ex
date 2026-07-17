defmodule CommsCore.Moderation.CaseView do
  @moduledoc "Stable moderation-case projection."
  defstruct [
    :id,
    :reporter_user_id,
    :subject_user_id,
    :conversation_id,
    :message_id,
    :assigned_to_user_id,
    :category,
    :summary,
    :details,
    :priority,
    :status,
    :resolved_at,
    :version,
    :inserted_at,
    :updated_at
  ]
end
