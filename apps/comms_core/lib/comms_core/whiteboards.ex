defmodule CommsCore.Whiteboards do
  @moduledoc "Durable, conversation-scoped collaborative whiteboards."

  # Conversations owns the reclamation contract; Collaboration implements it.
  # The dependency is inverted precisely because Collaboration already depends
  # on Conversations for authorization, and calling back directly would close a
  # business-context cycle. See ADR-0068.
  @behaviour CommsCore.Conversations.WhiteboardReclamationPort

  alias CommsCore.Conversations.WhiteboardReclamationReceipt
  alias CommsCore.Whiteboards.{Commands, Erasure, History, OperationView, Queries}

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

  defdelegate search(query, subject, opts \\ []), to: Queries
  defdelegate activity(conversation_id, subject, opts \\ []), to: Queries

  @doc "Contributes whiteboard erasure to an existing governance transaction."
  defdelegate erase_for_governance(tenant_id, target_type, target_id, timestamp),
    to: Erasure

  @doc "Contributes board reclamation to an expiring instant room's transaction."
  @impl CommsCore.Conversations.WhiteboardReclamationPort
  def discard_for_expired_room(tenant_id, conversation_id, timestamp) do
    case Erasure.discard_for_expired_room(tenant_id, conversation_id, timestamp) do
      {:ok, %{whiteboards_deleted: boards, whiteboard_operations_deleted: operations}} ->
        {:ok,
         %WhiteboardReclamationReceipt{
           whiteboards_deleted: boards,
           whiteboard_operations_deleted: operations
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
