defmodule CommsWorkers.FederationCommandWorker do
  use Oban.Worker, queue: :lifecycle, max_attempts: 12
  alias CommsCore.Conversations
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"command_id" => id}}) do
    with {:ok, mode} <- Conversations.prepare_federation_command(id, __MODULE__) do
      case Conversations.deliver_federation_command(id, __MODULE__, mode) do
        {:ok, :ok} ->
          :ok

        {:ok, {:retry, reason}} ->
          {:error, reason}

        {:error, :already_terminal} ->
          :ok

        {:error, reason} when reason in [:forbidden, :federation_command_stale] ->
          Conversations.cancel_stale_federation_command(id, __MODULE__)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def perform(_), do: {:discard, :invalid_federation_job}
end
