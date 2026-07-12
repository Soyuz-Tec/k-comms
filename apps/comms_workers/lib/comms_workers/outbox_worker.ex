defmodule CommsWorkers.OutboxWorker do
  use Oban.Worker, queue: :outbox, max_attempts: 20
  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}), do: {:error, :event_publisher_not_configured}
end
