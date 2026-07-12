defmodule CommsObservability.Metrics do
  use GenServer

  @table __MODULE__
  @buckets [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def record([:auth, :success], _measurements), do: increment(:auth_success_total)
  def record([:auth, :failure], _measurements), do: increment(:auth_failure_total)

  def record([:message, :commit], measurements) do
    duration = Map.get(measurements, :duration_seconds, 0.0)
    increment(:message_commit_total)
    increment(:message_commit_count)
    add(:message_commit_sum_microseconds, round(duration * 1_000_000))

    Enum.each(@buckets, fn bucket ->
      if duration <= bucket, do: increment({:message_commit_bucket, bucket})
    end)
  end

  def record(_event, _measurements), do: :ok

  def render(gauges \\ %{})

  def render(queue_age_seconds) when is_number(queue_age_seconds),
    do: render(%{queue_age_seconds: queue_age_seconds})

  def render(gauges) when is_map(gauges) do
    queue_age_seconds = Map.get(gauges, :queue_age_seconds, 0)

    lines = [
      "# HELP k_comms_auth_success_total Successful session authentications.",
      "# TYPE k_comms_auth_success_total counter",
      "k_comms_auth_success_total #{value(:auth_success_total)}",
      "# HELP k_comms_auth_failure_total Failed session or token authentications.",
      "# TYPE k_comms_auth_failure_total counter",
      "k_comms_auth_failure_total #{value(:auth_failure_total)}",
      "# HELP k_comms_message_commit_duration_seconds Durable message commit latency.",
      "# TYPE k_comms_message_commit_duration_seconds histogram"
    ]

    buckets =
      Enum.map(@buckets, fn bucket ->
        "k_comms_message_commit_duration_seconds_bucket{le=\"#{bucket}\"} #{value({:message_commit_bucket, bucket})}"
      end)

    tail = [
      "k_comms_message_commit_duration_seconds_bucket{le=\"+Inf\"} #{value(:message_commit_count)}",
      "k_comms_message_commit_duration_seconds_sum #{value(:message_commit_sum_microseconds) / 1_000_000}",
      "k_comms_message_commit_duration_seconds_count #{value(:message_commit_count)}",
      "# HELP k_comms_oban_queue_age_seconds Age of the oldest runnable durable job.",
      "# TYPE k_comms_oban_queue_age_seconds gauge",
      "k_comms_oban_queue_age_seconds #{queue_age_seconds}",
      "# HELP k_comms_oban_jobs_pending Runnable or retryable durable jobs.",
      "# TYPE k_comms_oban_jobs_pending gauge",
      "k_comms_oban_jobs_pending #{Map.get(gauges, :jobs_pending, 0)}",
      "# HELP k_comms_oban_jobs_discarded Discarded durable jobs requiring review.",
      "# TYPE k_comms_oban_jobs_discarded gauge",
      "k_comms_oban_jobs_discarded #{Map.get(gauges, :jobs_discarded, 0)}",
      "# HELP k_comms_outbox_pending Unpublished transactional outbox events.",
      "# TYPE k_comms_outbox_pending gauge",
      "k_comms_outbox_pending #{Map.get(gauges, :outbox_pending, 0)}",
      "# HELP k_comms_attachments_quarantined Attachments awaiting or failing safety approval.",
      "# TYPE k_comms_attachments_quarantined gauge",
      "k_comms_attachments_quarantined #{Map.get(gauges, :attachments_quarantined, 0)}",
      "# HELP k_comms_notification_failures Durable notification intents in failed state.",
      "# TYPE k_comms_notification_failures gauge",
      "k_comms_notification_failures #{Map.get(gauges, :notification_failures, 0)}",
      "# HELP k_comms_webhook_failures Durable webhook deliveries in failed state.",
      "# TYPE k_comms_webhook_failures gauge",
      "k_comms_webhook_failures #{Map.get(gauges, :webhook_failures, 0)}",
      "# HELP k_comms_attachment_scan_failures Attachments with a failed scanner attempt.",
      "# TYPE k_comms_attachment_scan_failures gauge",
      "k_comms_attachment_scan_failures #{Map.get(gauges, :attachment_scan_failures, 0)}",
      "# HELP k_comms_beam_process_count Current BEAM process count.",
      "# TYPE k_comms_beam_process_count gauge",
      "k_comms_beam_process_count #{:erlang.system_info(:process_count)}",
      "# HELP k_comms_beam_memory_bytes Total memory allocated by the BEAM runtime.",
      "# TYPE k_comms_beam_memory_bytes gauge",
      "k_comms_beam_memory_bytes #{:erlang.memory(:total)}"
    ]

    Enum.join(lines ++ buckets ++ tail, "\n") <> "\n"
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  defp increment(key) do
    if :ets.whereis(@table) != :undefined do
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
    end

    :ok
  end

  defp add(key, amount) do
    if :ets.whereis(@table) != :undefined do
      :ets.update_counter(@table, key, {2, amount}, {key, 0})
    end

    :ok
  end

  defp value(key) do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, result}] -> result
          [] -> 0
        end
    end
  end
end
