defmodule CommsCore.Conversations.WhiteboardReclamationPort do
  @moduledoc """
  Conversations-owned port for transaction-scoped whiteboard reclamation.

  Instant-room expiry has to reclaim the room's board in the same transaction
  that ends access to it (ADR-0068), but Collaboration already depends on
  Conversations for authorization. Calling back the other way would close a
  business-context cycle, which the architecture gate rejects.

  The dependency is therefore inverted: Conversations declares what it needs,
  Collaboration provides it, and the binding is resolved from configuration at
  runtime rather than compiled in. This mirrors
  `CommsCore.Conversations.CallLifecyclePort`.
  """

  alias CommsCore.Conversations.WhiteboardReclamationReceipt
  alias CommsCore.Repo

  @callback discard_for_expired_room(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
              {:ok, WhiteboardReclamationReceipt.t()} | {:error, term()}

  @spec discard_for_expired_room(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, WhiteboardReclamationReceipt.t()} | {:error, term()}
  def discard_for_expired_room(tenant_id, conversation_id, %DateTime{} = timestamp) do
    # The caller's transaction is the whole point: reclaiming after the expiry
    # commit would leave the rows outliving the authority to read them, and a
    # crash in that window would leak them permanently.
    if Repo.in_transaction?() do
      with :ok <- validate_scope(tenant_id, conversation_id),
           {:ok, adapter} <- configured_adapter() do
        validate_result(adapter.discard_for_expired_room(tenant_id, conversation_id, timestamp))
      end
    else
      {:error, :transaction_required}
    end
  end

  def discard_for_expired_room(_tenant_id, _conversation_id, _timestamp),
    do: {:error, :invalid_whiteboard_reclamation_scope}

  defp configured_adapter do
    with {:ok, adapter} <-
           Application.fetch_env(:comms_core, :conversation_whiteboard_reclamation_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :discard_for_expired_room, 3) do
      {:ok, adapter}
    else
      _ -> {:error, :whiteboard_reclamation_unavailable}
    end
  end

  defp validate_scope(tenant_id, conversation_id) do
    if valid_uuid?(tenant_id) and valid_uuid?(conversation_id),
      do: :ok,
      else: {:error, :invalid_whiteboard_reclamation_scope}
  end

  defp validate_result(
         {:ok,
          %WhiteboardReclamationReceipt{
            whiteboards_deleted: boards,
            whiteboard_operations_deleted: operations
          } = receipt}
       )
       when is_integer(boards) and boards >= 0 and is_integer(operations) and operations >= 0 do
    {:ok, receipt}
  end

  defp validate_result({:error, _reason} = error), do: error
  defp validate_result(_result), do: {:error, :whiteboard_reclamation_unavailable}

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
end
