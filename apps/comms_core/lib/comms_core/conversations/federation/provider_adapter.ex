defmodule CommsCore.Conversations.Federation.ProviderAdapter do
  alias CommsCore.Conversations.Federation.{ProviderRequest, ProviderReceipt}
  alias CommsCore.Repo
  @spec perform(ProviderRequest.t()) :: {:ok, ProviderReceipt.t()} | {:error, atom()}
  def perform(%ProviderRequest{} = request) do
    if Repo.in_transaction?() do
      with {:ok, adapter} <- Application.fetch_env(:comms_core, :federation_provider_adapter),
           true <-
             is_atom(adapter) and Code.ensure_loaded?(adapter) and
               function_exported?(adapter, :perform, 1),
           {:ok, %ProviderReceipt{} = result} <- adapter.perform(request),
           true <-
             result.operation == request.operation and result.remote_deletion_confirmed == false and
               valid_observation?(result) do
        {:ok, result}
      else
        {:error, _} = error -> error
        _ -> {:error, :federation_provider_contract_invalid}
      end
    else
      {:error, :transaction_required}
    end
  end

  defp valid_observation?(%ProviderReceipt{operation: :create, room_id: room}),
    do: is_binary(room) and byte_size(room) in 1..255 and String.starts_with?(room, "!")

  defp valid_observation?(%ProviderReceipt{operation: operation, event_id: event})
       when operation in [:send, :recover_event],
       do: is_binary(event) and byte_size(event) in 1..255

  defp valid_observation?(%ProviderReceipt{operation: :invite, state: state}),
    do: state in ["invited", "joined"]

  defp valid_observation?(%ProviderReceipt{operation: :redact, local_redaction_observed: true}),
    do: true

  defp valid_observation?(%ProviderReceipt{operation: :leave, local_absence_observed: true}),
    do: true

  defp valid_observation?(%ProviderReceipt{operation: :close, local_leave_observed: true}),
    do: true

  defp valid_observation?(%ProviderReceipt{
         operation: :timeline,
         events: events,
         joined: joined,
         cursor: cursor
       })
       when is_list(events) and length(events) <= 50 and is_list(joined) and length(joined) <= 101 do
    (is_nil(cursor) or (is_binary(cursor) and byte_size(cursor) in 1..2048)) and
      Enum.all?(joined, &(is_binary(&1) and byte_size(&1) in 1..255)) and
      Enum.all?(events, fn
        %{event_id: event, sender: sender, body: body, timestamp: timestamp} ->
          is_binary(event) and byte_size(event) in 1..255 and sender in joined and
            is_binary(body) and byte_size(body) in 1..16_384 and is_integer(timestamp) and
            timestamp >= 0

        _ ->
          false
      end)
  end

  defp valid_observation?(_), do: false
end
