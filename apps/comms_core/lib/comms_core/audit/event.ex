defmodule CommsCore.Audit.Event do
  @moduledoc "Public, persistence-neutral audit event projection."

  @enforce_keys [:id, :tenant_id, :action, :resource_type, :resource_id, :metadata, :inserted_at]
  defstruct [
    :id,
    :tenant_id,
    :actor_user_id,
    :action,
    :resource_type,
    :resource_id,
    :metadata,
    :request_id,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t() | nil,
          action: String.t(),
          resource_type: String.t(),
          resource_id: Ecto.UUID.t(),
          metadata: map(),
          request_id: String.t() | nil,
          inserted_at: DateTime.t()
        }

  @doc false
  def from_schema(event) do
    %__MODULE__{
      id: event.id,
      tenant_id: event.tenant_id,
      actor_user_id: event.actor_user_id,
      action: event.action,
      resource_type: event.resource_type,
      resource_id: event.resource_id,
      metadata: event.metadata,
      request_id: event.request_id,
      inserted_at: event.inserted_at
    }
  end
end
