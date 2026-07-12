defmodule CommsCore.Outbox do
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Repo

  @worker "CommsWorkers.OutboxWorker"

  def insert_and_enqueue!(attrs) when is_map(attrs) do
    event =
      %OutboxEvent{}
      |> OutboxEvent.changeset(attrs)
      |> Repo.insert!()

    %{"event_id" => event.id}
    |> Oban.Job.new(worker: @worker, queue: :outbox)
    |> Repo.insert!()

    event
  end
end
