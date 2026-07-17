defmodule CommsCore.Governance.RetentionPolicyView do
  @moduledoc "Stable retention-policy projection."
  defstruct [
    :id,
    :conversation_id,
    :name,
    :scope_type,
    :retention_days,
    :delete_attachments,
    :status,
    :version,
    :inserted_at,
    :updated_at
  ]
end
