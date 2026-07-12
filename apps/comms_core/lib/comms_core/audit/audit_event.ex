defmodule CommsCore.Audit.AuditEvent do
  use CommsCore.Schema

  schema "audit_events" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    belongs_to(:actor_user, CommsCore.Accounts.User)
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
