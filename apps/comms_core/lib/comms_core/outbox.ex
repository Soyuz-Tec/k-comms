defmodule CommsCore.Outbox do
  import Ecto.Query

  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Outbox.Event
  alias CommsCore.{Repo, RuntimePorts}

  def insert_and_enqueue!(attrs) when is_map(attrs) do
    event =
      %OutboxEvent{}
      |> OutboxEvent.changeset(attrs)
      |> Repo.insert!()

    %{"event_id" => event.id, "tenant_id" => event.tenant_id}
    |> Oban.Job.new(worker: RuntimePorts.job_worker_name!(:outbox_publication), queue: :outbox)
    |> Repo.insert!()

    event
  end

  def fetch_for_publication(event_id, caller) do
    if RuntimePorts.authorized_job_worker?(:outbox_publication, caller) do
      case Repo.get(OutboxEvent, event_id) do
        nil ->
          :not_found

        %OutboxEvent{published_at: published_at} when not is_nil(published_at) ->
          :already_published

        %OutboxEvent{} = event ->
          {:ok, Event.new(event)}
      end
    else
      {:error, :forbidden}
    end
  end

  def mark_published(event_id, caller) do
    if RuntimePorts.authorized_job_worker?(:outbox_publication, caller) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      query =
        from(event in OutboxEvent,
          where: event.id == ^event_id and is_nil(event.published_at)
        )

      case Repo.update_all(query, set: [published_at: now], inc: [attempts: 1]) do
        {1, _} -> :ok
        {0, _} -> :ok
      end
    else
      {:error, :forbidden}
    end
  end

  def record_attempt(event_id, caller) do
    if RuntimePorts.authorized_job_worker?(:outbox_publication, caller) do
      OutboxEvent
      |> where([event], event.id == ^event_id)
      |> Repo.update_all(inc: [attempts: 1])

      :ok
    else
      {:error, :forbidden}
    end
  end
end
