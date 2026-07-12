defmodule CommsWorkers.RetentionWorker do
  use Oban.Worker, queue: :default, max_attempts: 10

  alias CommsCore.Governance

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    case Governance.enqueue_due_retention(tenant_id, __MODULE__) do
      {:ok, result} ->
        schedule_next(tenant_id, if(result.has_more, do: 1, else: 86_400))
        :ok

      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_job), do: {:discard, :tenant_id_required}

  defp schedule_next(tenant_id, seconds) do
    %{"tenant_id" => tenant_id}
    |> Oban.Job.new(
      worker: __MODULE__,
      queue: :default,
      scheduled_in: seconds,
      unique: [
        period: 300,
        fields: [:worker, :args],
        states: [:available, :scheduled, :retryable]
      ]
    )
    |> Oban.insert()
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
end
