defmodule CommsCore.Whiteboards.Projector do
  @moduledoc false

  alias CommsCore.Whiteboards.{Operation, OperationView}

  @spec operation(Operation.t()) :: OperationView.t()
  def operation(%Operation{} = operation) do
    struct!(OperationView, %{
      id: operation.id,
      whiteboard_id: operation.whiteboard_id,
      tenant_id: operation.tenant_id,
      conversation_id: operation.conversation_id,
      actor_user_id: operation.actor_user_id,
      client_operation_id: operation.client_operation_id,
      sequence: operation.sequence,
      kind: operation.kind,
      payload: operation.payload,
      inserted_at: operation.inserted_at
    })
  end
end
