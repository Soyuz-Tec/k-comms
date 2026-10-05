defmodule CommsWorkers.PrivateRoomPurgeReconcilerWorker do
  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 20,
    unique: [period: 55, fields: [:worker], states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when args == %{} do
    case CommsCore.Conversations.reconcile_private_room_purges(__MODULE__) do
      {:ok, %{scanned: _, provider_purged: _}} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :private_room_purge_unconfirmed}
    end
  end

  def perform(_), do: {:discard, :invalid_private_purge_job}
end
