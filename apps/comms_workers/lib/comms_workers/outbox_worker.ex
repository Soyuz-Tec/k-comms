defmodule CommsWorkers.OutboxWorker do
  use Oban.Worker, queue: :outbox, max_attempts: 20

  alias CommsCore.Integrations
  alias CommsCore.Notifications
  alias CommsCore.Outbox

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    case Outbox.fetch_for_publication(event_id, __MODULE__) do
      :not_found ->
        {:discard, :event_not_found}

      :already_published ->
        :ok

      {:ok, event} ->
        with :ok <- Notifications.enqueue_for_event(event),
             :ok <- Integrations.enqueue_for_event(event) do
          Outbox.mark_published(event.id, __MODULE__)
        else
          {:error, reason} ->
            :ok = Outbox.record_attempt(event.id, __MODULE__)
            {:error, reason}
        end

      {:error, :forbidden} = error ->
        error
    end
  end

  def perform(_job), do: {:discard, :event_id_required}
end
