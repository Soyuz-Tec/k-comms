defmodule CommsWorkers.EphemeralRoomReconcilerWorker do
  @moduledoc """
  Reconciles ephemeral room presence after the reconnect grace window.

  Room-specific jobs are generation fenced. The minute cron invocation carries
  no arguments and asks the Conversations context to scan at most its configured
  bounded batch, restoring convergence after crashes or missed notifications.
  """

  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 20,
    unique: [
      period: 55,
      fields: [:worker, :args],
      keys: [:room_id, :generation],
      states: :incomplete
    ]

  alias CommsCore.Conversations

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"room_id" => room_id, "generation" => generation}
      })
      when is_binary(room_id) and is_integer(generation) and generation >= 1 do
    case Conversations.reconcile_ephemeral_room(room_id, generation, __MODULE__) do
      {:ok, status} when status in [:active, :already_terminal, :stale_generation] ->
        :ok

      {:ok, {:idle, %DateTime{}, new_generation}}
      when is_integer(new_generation) and new_generation >= 1 ->
        :ok

      {:error, :ephemeral_room_not_found} ->
        {:discard, :ephemeral_room_not_found}

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    case Conversations.reconcile_ephemeral_rooms(__MODULE__) do
      {:ok, %{scanned: scanned, reconciled: reconciled}}
      when is_integer(scanned) and scanned >= 0 and is_integer(reconciled) and
             reconciled >= 0 ->
        :ok

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :room_id_and_generation_required}

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :ephemeral_room_reconciliation_failed
end
