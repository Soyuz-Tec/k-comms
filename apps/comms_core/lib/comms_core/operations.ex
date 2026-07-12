defmodule CommsCore.Operations do
  import Ecto.Query

  alias CommsCore.{Attachments, Authorization, Integrations, Notifications, Repo}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Integrations.WebhookDelivery
  alias CommsCore.Notifications.Intent

  def snapshot(subject) do
    with :ok <- Authorization.authorize(:administer_tenant, subject, %{}) do
      tenant_id = value(subject, :tenant_id)

      {:ok,
       %{
         generated_at: now(),
         queues: queue_counts(tenant_id),
         outbox: outbox_counts(tenant_id),
         notifications: grouped_counts(Intent, tenant_id, :status),
         webhooks: grouped_counts(WebhookDelivery, tenant_id, :status),
         attachments: grouped_counts(Attachment, tenant_id, :scan_status)
       }}
    end
  end

  def platform_snapshot(subject) do
    with :ok <- Authorization.authorize(:view_platform_operations, subject, %{}) do
      {:ok,
       %{
         generated_at: now(),
         database: database_health(),
         queues: queue_counts(nil),
         outbox: outbox_counts(nil),
         notifications: grouped_counts(Intent, nil, :status),
         webhooks: grouped_counts(WebhookDelivery, nil, :status),
         attachments: grouped_counts(Attachment, nil, :scan_status)
       }}
    end
  end

  def retry("notification", id, subject), do: Notifications.retry_intent(id, subject)
  def retry("webhook", id, subject), do: Integrations.replay_delivery(id, subject)
  def retry("attachment_scan", id, subject), do: Attachments.retry_scan(id, subject)
  def retry(_, _, _), do: {:error, :unsupported_operation}

  defp database_health do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> %{status: :available}
      {:error, _} -> %{status: :unavailable}
    end
  end

  defp queue_counts(tenant_id) do
    Oban.Job
    |> maybe_queue_tenant(tenant_id)
    |> group_by([job], [job.queue, job.state])
    |> select([job], %{
      queue: job.queue,
      state: job.state,
      count: count(job.id),
      oldest_scheduled_at: min(job.scheduled_at)
    })
    |> order_by([job], asc: job.queue, asc: job.state)
    |> Repo.all()
  end

  defp maybe_queue_tenant(query, nil), do: query

  defp maybe_queue_tenant(query, tenant_id) do
    where(query, [job], fragment("?->>'tenant_id' = ?", job.args, ^tenant_id))
  end

  defp outbox_counts(tenant_id) do
    base = maybe_record_tenant(OutboxEvent, tenant_id)

    pending =
      Repo.aggregate(
        from(event in base, where: is_nil(event.published_at)),
        :count
      )

    published =
      Repo.aggregate(
        from(event in base, where: not is_nil(event.published_at)),
        :count
      )

    %{pending: pending, published: published}
  end

  defp grouped_counts(schema, tenant_id, field) do
    schema
    |> maybe_record_tenant(tenant_id)
    |> group_by([record], field(record, ^field))
    |> select([record], {field(record, ^field), count(record.id)})
    |> Repo.all()
    |> Map.new(fn {status, count} -> {status, count} end)
  end

  defp maybe_record_tenant(query, nil), do: query

  defp maybe_record_tenant(query, tenant_id),
    do: where(query, [record], record.tenant_id == ^tenant_id)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
