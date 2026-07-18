defmodule CommsCore.Outbox.Event do
  @moduledoc """
  Stable event envelope exposed to post-commit publishers.

  Publication state and the backing Ecto schema remain private to the platform-eventing owner.
  """

  @derive {Inspect, except: [:payload]}
  @enforce_keys [:id, :tenant_id, :event_type, :aggregate_type, :aggregate_id, :payload]
  defstruct [
    :id,
    :tenant_id,
    :event_type,
    :aggregate_type,
    :aggregate_id,
    :payload,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          event_type: String.t(),
          aggregate_type: String.t(),
          aggregate_id: String.t(),
          payload: map(),
          inserted_at: DateTime.t() | nil
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, Map.take(attrs, __struct__() |> Map.keys() |> List.delete(:__struct__)))
  end
end
