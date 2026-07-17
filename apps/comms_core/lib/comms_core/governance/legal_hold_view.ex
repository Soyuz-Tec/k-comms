defmodule CommsCore.Governance.LegalHoldView do
  @moduledoc "Stable legal-hold projection."
  defstruct [
    :id,
    :created_by_user_id,
    :subject_user_id,
    :conversation_id,
    :name,
    :reason,
    :scope_type,
    :status,
    :starts_at,
    :released_at,
    :version,
    :inserted_at
  ]
end
