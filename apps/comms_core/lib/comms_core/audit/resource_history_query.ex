defmodule CommsCore.Audit.ResourceHistoryQuery do
  @moduledoc "Bounded chronological audit history for one exact tenant resource."
  @enforce_keys [:tenant_id, :resource_type, :resource_id, :actions, :origin_action, :limit]
  defstruct [
    :tenant_id,
    :resource_type,
    :resource_id,
    :actions,
    :origin_action,
    :after,
    :snapshot_id,
    :deadline,
    :limit
  ]

  @type boundary :: {DateTime.t(), Ecto.UUID.t()}
  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          resource_type: String.t(),
          resource_id: Ecto.UUID.t(),
          actions: [String.t()],
          origin_action: String.t(),
          after: boundary() | nil,
          snapshot_id: Ecto.UUID.t() | nil,
          deadline: integer() | nil,
          limit: 1..5_000
        }
end
