defmodule CommsCore.Audit.ResourceHistorySnapshot do
  @moduledoc false
  use CommsCore.Schema

  schema "audit_resource_history_snapshots" do
    field(:tenant_id, :binary_id)
    field(:resource_type, :string)
    field(:resource_id, :binary_id)
    field(:actions, {:array, :string})
    field(:origin_action, :string)
    field(:event_ids, {:array, :binary_id})
    field(:truncated, :boolean)
    field(:observed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
  end
end
