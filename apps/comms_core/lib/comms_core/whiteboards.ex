defmodule CommsCore.Whiteboards do
  @moduledoc "Durable, conversation-scoped collaborative whiteboards."

  alias CommsCore.Whiteboards.{Commands, Erasure, History, OperationView}

  @spec append_operation(Ecto.UUID.t(), map(), map()) ::
          {:ok, OperationView.t(), :created | :duplicate}
          | {:error,
             :forbidden
             | :idempotency_conflict
             | :invalid_whiteboard_operation
             | :stale_whiteboard_generation
             | :whiteboard_capacity_exceeded}
  def append_operation(conversation_id, attrs, subject),
    do: Commands.append(conversation_id, attrs, subject)

  @spec list_operations(Ecto.UUID.t(), map(), keyword()) ::
          {:ok,
           %{
             operations: [OperationView.t()],
             has_more: boolean(),
             next_after_sequence: non_neg_integer()
           }}
          | {:error, :forbidden}
  def list_operations(conversation_id, subject, opts \\ []),
    do: History.list(conversation_id, subject, opts)

  @doc "Contributes whiteboard erasure to an existing governance transaction."
  defdelegate erase_for_governance(tenant_id, target_type, target_id, timestamp),
    to: Erasure
end
