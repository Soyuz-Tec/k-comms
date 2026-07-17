defmodule CommsCore.Audit.AuditEvent do
  @moduledoc false

  use CommsCore.Schema

  schema "audit_events" do
    field(:tenant_id, :binary_id)
    field(:actor_user_id, :binary_id)
    field(:action, :string)
    field(:resource_type, :string)
    field(:resource_id, :binary_id)
    field(:metadata, :map)
    field(:request_id, :string)
    timestamps(updated_at: false)
  end

  def changeset(value, attrs),
    do:
      value
      |> cast(attrs, [
        :tenant_id,
        :actor_user_id,
        :action,
        :resource_type,
        :resource_id,
        :metadata,
        :request_id
      ])
      |> validate_required([:tenant_id, :action, :resource_type, :resource_id, :metadata])
end
