defmodule CommsCore.Outbox do
  alias CommsCore.Events.OutboxStore
  alias CommsCore.Outbox.Event
  alias CommsCore.RuntimePorts

  @doc """
  Atomically appends a durable event and schedules its publication.

  The owning context must call this function inside its active transaction.
  """
  @spec insert_and_enqueue!(map()) :: Event.t()
  def insert_and_enqueue!(attrs) when is_map(attrs) do
    OutboxStore.insert_and_enqueue!(attrs)
  end

  @spec fetch_for_publication(String.t(), module()) ::
          {:ok, Event.t()} | :not_found | :already_published | {:error, :forbidden}
  def fetch_for_publication(event_id, caller) do
    if RuntimePorts.authorized_job_worker?(:outbox_publication, caller) do
      OutboxStore.fetch_for_publication(event_id)
    else
      {:error, :forbidden}
    end
  end

  @spec mark_published(String.t(), module()) :: :ok | {:error, :forbidden}
  def mark_published(event_id, caller) do
    if RuntimePorts.authorized_job_worker?(:outbox_publication, caller) do
      OutboxStore.mark_published(event_id)
    else
      {:error, :forbidden}
    end
  end

  @spec record_attempt(String.t(), module()) :: :ok | {:error, :forbidden}
  def record_attempt(event_id, caller) do
    if RuntimePorts.authorized_job_worker?(:outbox_publication, caller) do
      OutboxStore.record_attempt(event_id)
    else
      {:error, :forbidden}
    end
  end
end
