defmodule CommsCore.Events.OutboxStore do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Outbox.Event
  alias CommsCore.{Repo, RuntimePorts}

  @attempt_recorded_event [:k_comms, :outbox, :attempt, :recorded]

  @spec insert_and_enqueue!(map()) :: Event.t()
  def insert_and_enqueue!(attrs) when is_map(attrs) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "CommsCore.Outbox.insert_and_enqueue!/1 requires an active owner transaction"
    end

    event =
      %OutboxEvent{}
      |> OutboxEvent.changeset(attrs)
      |> Repo.insert!()

    %{"event_id" => event.id, "tenant_id" => event.tenant_id}
    |> Oban.Job.new(worker: RuntimePorts.job_worker_name!(:outbox_publication), queue: :outbox)
    |> Repo.insert!()

    Event.new(event)
  end

  @spec fetch_for_publication(Ecto.UUID.t()) ::
          {:ok, Event.t()} | :not_found | :already_published
  def fetch_for_publication(event_id) do
    case Repo.get(OutboxEvent, event_id) do
      nil ->
        :not_found

      %OutboxEvent{published_at: published_at} when not is_nil(published_at) ->
        :already_published

      %OutboxEvent{} = event ->
        {:ok, Event.new(event)}
    end
  end

  @spec mark_published(Ecto.UUID.t()) :: :ok
  def mark_published(event_id) do
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

  @spec record_attempt(Ecto.UUID.t()) :: :ok
  def record_attempt(event_id) do
    case OutboxEvent
         |> where([event], event.id == ^event_id)
         |> Repo.update_all(inc: [attempts: 1]) do
      {1, _} ->
        :telemetry.execute(@attempt_recorded_event, %{count: 1}, %{event_id: event_id})

      {0, _} ->
        :ok
    end

    :ok
  end
end
