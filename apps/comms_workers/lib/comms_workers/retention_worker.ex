defmodule CommsWorkers.RetentionWorker do
  use Oban.Worker, queue: :default, max_attempts: 10

  alias CommsCore.Governance

  @impl Oban.Worker
  def perform(job), do: perform(job, &Oban.insert/1)

  @doc false
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id} = args}, insert_job)
      when is_function(insert_job, 1) do
    with {:ok, result} <-
           Governance.enqueue_due_retention(tenant_id, __MODULE__, Map.get(args, "cursor")),
         {:ok, _job} <- schedule_next(tenant_id, result, insert_job) do
      :ok
    else
      {:error, reason} ->
        {:error, safe_reason(reason)}
    end
  end

  def perform(_job, _insert_job), do: {:discard, :tenant_id_required}

  defp schedule_next(tenant_id, result, insert_job) do
    args =
      if result.has_more,
        do: %{"tenant_id" => tenant_id, "cursor" => result.next_cursor},
        else: %{"tenant_id" => tenant_id}

    args
    |> Oban.Job.new(
      worker: __MODULE__,
      queue: :default,
      scheduled_in: if(result.has_more, do: 1, else: 86_400),
      unique: [
        period: 300,
        fields: [:worker, :args],
        states: [:available, :scheduled, :retryable]
      ]
    )
    |> insert_job.()
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :retention_scheduling_failed
end
