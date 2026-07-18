defmodule CommsCore.Conversations.CallLifecyclePort do
  @moduledoc """
  Conversations-owned port for transaction-scoped call admission revocation.
  """

  alias CommsCore.Conversations.{CallLifecycleCommand, CallLifecycleReceipt}
  alias CommsCore.Repo

  @callback revoke_conversation_access(CallLifecycleCommand.t()) ::
              {:ok, CallLifecycleReceipt.t()} | {:error, term()}

  @spec revoke_conversation_access(CallLifecycleCommand.t()) ::
          {:ok, CallLifecycleReceipt.t()} | {:error, term()}
  def revoke_conversation_access(%CallLifecycleCommand{} = command) do
    if Repo.in_transaction?() do
      with :ok <- validate_command(command),
           {:ok, adapter} <- configured_adapter(),
           result <- adapter.revoke_conversation_access(command) do
        validate_result(result)
      end
    else
      {:error, :transaction_required}
    end
  end

  def revoke_conversation_access(_command), do: {:error, :invalid_call_lifecycle_command}

  defp configured_adapter do
    with {:ok, adapter} <-
           Application.fetch_env(:comms_core, :conversation_call_lifecycle_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :revoke_conversation_access, 1) do
      {:ok, adapter}
    else
      _ -> {:error, :call_lifecycle_unavailable}
    end
  end

  defp validate_command(%CallLifecycleCommand{
         operation: :membership_revoked,
         tenant_id: tenant_id,
         conversation_id: conversation_id,
         user_id: user_id,
         reason: reason
       }) do
    if valid_uuid?(tenant_id) and valid_uuid?(conversation_id) and valid_uuid?(user_id) and
         valid_reason?(reason),
       do: :ok,
       else: {:error, :invalid_call_lifecycle_command}
  end

  defp validate_command(%CallLifecycleCommand{
         operation: :conversation_archived,
         tenant_id: tenant_id,
         conversation_id: conversation_id,
         user_id: nil,
         reason: reason
       }) do
    if valid_uuid?(tenant_id) and valid_uuid?(conversation_id) and valid_reason?(reason),
      do: :ok,
      else: {:error, :invalid_call_lifecycle_command}
  end

  defp validate_command(_command), do: {:error, :invalid_call_lifecycle_command}

  defp validate_result({:ok, %CallLifecycleReceipt{revoked_participant_count: count} = receipt})
       when is_integer(count) and count >= 0,
       do: {:ok, receipt}

  defp validate_result({:error, _reason} = error), do: error
  defp validate_result(_result), do: {:error, :call_lifecycle_unavailable}

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp valid_reason?(value), do: is_binary(value) and String.trim(value) != ""
end
