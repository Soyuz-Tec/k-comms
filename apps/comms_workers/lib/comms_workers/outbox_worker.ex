defmodule CommsWorkers.OutboxWorker do
  use Oban.Worker, queue: :outbox, max_attempts: 20

  import Ecto.Query

  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Integrations
  alias CommsCore.Notifications
  alias CommsCore.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    case Repo.get(OutboxEvent, event_id) do
      nil ->
        {:discard, :event_not_found}

      %OutboxEvent{published_at: published_at} when not is_nil(published_at) ->
        :ok

      %OutboxEvent{} = event ->
        with :ok <- Notifications.enqueue_for_event(event),
             :ok <- Integrations.enqueue_for_event(event) do
          mark_published(event.id)
        else
          {:error, reason} -> record_attempt(event.id, reason)
        end
    end
  end

  def perform(_job), do: {:discard, :event_id_required}

  defp mark_published(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(event in OutboxEvent,
        where: event.id == ^event_id and is_nil(event.published_at)
      )

    case Repo.update_all(query, set: [published_at: now], inc: [attempts: 1]) do
      {1, _} -> :ok
      {0, _} -> :ok
    end
  end

  defp record_attempt(event_id, reason) do
    OutboxEvent
    |> where([event], event.id == ^event_id)
    |> Repo.update_all(inc: [attempts: 1])

    {:error, reason}
  end
end
