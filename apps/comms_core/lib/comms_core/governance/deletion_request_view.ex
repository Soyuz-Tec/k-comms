defmodule CommsCore.Governance.DeletionRequestView do
  @moduledoc "Stable deletion-request projection."
  defstruct [
    :id,
    :requested_by_user_id,
    :subject_user_id,
    :conversation_id,
    :message_id,
    :target_type,
    :reason,
    :status,
    :scheduled_for,
    :completed_at,
    :execution_started_at,
    :execution_attempts,
    :execution_error,
    :evidence,
    :version,
    :inserted_at,
    :updated_at
  ]
end
