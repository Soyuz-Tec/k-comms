defmodule CommsWorkers.CallSummaryWorker do
  @moduledoc "Durable one-use consented summary generation and retained summary erasure."
  use Oban.Worker, queue: :media, max_attempts: 30
  alias CommsCore.AudioCalls
  @impl true
  def perform(%Oban.Job{args: %{"artifact_id" => id}}) when is_binary(id) do
    case AudioCalls.process_artifact(id, __MODULE__) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:discard, :artifact_not_found}
      {:error, :artifact_legal_hold} -> {:snooze, 3_600}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :artifact_processing_failed}
    end
  end

  def perform(_), do: {:discard, :artifact_id_required}
end
