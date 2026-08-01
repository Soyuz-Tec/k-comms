defmodule CommsCore.Whiteboards.Operation do
  @moduledoc false

  use CommsCore.Schema

  @kinds ["scene.update", "board.clear"]

  schema "whiteboard_operations" do
    field(:whiteboard_id, Ecto.UUID)
    field(:tenant_id, Ecto.UUID)
    field(:conversation_id, Ecto.UUID)
    field(:actor_user_id, Ecto.UUID)
    field(:actor_device_id, Ecto.UUID)
    field(:client_operation_id, :string)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:payload, :map, default: %{})
    timestamps(updated_at: false)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :whiteboard_id,
      :tenant_id,
      :conversation_id,
      :actor_user_id,
      :actor_device_id,
      :client_operation_id,
      :sequence,
      :kind,
      :payload
    ])
    |> validate_required([
      :whiteboard_id,
      :tenant_id,
      :conversation_id,
      :actor_user_id,
      :actor_device_id,
      :client_operation_id,
      :sequence,
      :kind,
      :payload
    ])
    |> validate_length(:client_operation_id, min: 8, max: 128)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:whiteboard_id, :sequence],
      name: :whiteboard_operations_board_sequence_unique
    )
    |> unique_constraint(
      [:tenant_id, :actor_device_id, :conversation_id, :client_operation_id],
      name: :whiteboard_operations_idempotency_unique
    )
  end
end
