defmodule CommsObservability.Metrics do
  use GenServer

  @table __MODULE__
  @buckets [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]

  # The peer-link label sets are closed here as well as at the channel that
  # validates the reported outcome. Cardinality is therefore fixed at compile
  # time and no participant, tenant, call, or address identifier can reach a
  # label even if a future caller passes one.
  @peer_link_candidate_classes ["host", "srflx", "relay"]
  @peer_link_fallback_reasons [
    "ice_timeout",
    "signaling",
    "declined",
    "ineligible",
    "duplicate_connection",
    "moderation"
  ]
  @peer_link_buckets [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 12.0]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def peer_link_candidate_classes, do: @peer_link_candidate_classes
  def peer_link_fallback_reasons, do: @peer_link_fallback_reasons

  def record([:auth, :success], _measurements), do: increment(:auth_success_total)
  def record([:auth, :failure], _measurements), do: increment(:auth_failure_total)

  def record([:peer_link, :attempt], _measurements), do: increment(:peer_link_attempt_total)

  def record([:peer_link, :connected], measurements) do
    case Map.get(measurements, :candidate_class) do
      class when class in @peer_link_candidate_classes ->
        increment({:peer_link_connection, class})

      _ ->
        :ok
    end

    observe_peer_link_connect(Map.get(measurements, :duration_seconds))
  end

  def record([:peer_link, :fallback], measurements) do
    case Map.get(measurements, :reason) do
      reason when reason in @peer_link_fallback_reasons ->
        increment({:peer_link_fallback, reason})

      _ ->
        :ok
    end
  end

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
      "# HELP k_comms_attachment_cleanup_failures Abandoned attachment keys awaiting recovery after exhausted cleanup attempts.",
      "# TYPE k_comms_attachment_cleanup_failures gauge",
      "k_comms_attachment_cleanup_failures #{Map.get(gauges, :attachment_cleanup_failures, 0)}",
      "# HELP k_comms_beam_process_count Current BEAM process count.",
      "# TYPE k_comms_beam_process_count gauge",
      "k_comms_beam_process_count #{:erlang.system_info(:process_count)}",
      "# HELP k_comms_beam_memory_bytes Total memory allocated by the BEAM runtime.",
      "# TYPE k_comms_beam_memory_bytes gauge",
      "k_comms_beam_memory_bytes #{:erlang.memory(:total)}"
    ]

    Enum.join(lines ++ buckets ++ tail ++ peer_link(), "\n") <> "\n"
  end

  defp peer_link do
    [
      "# HELP k_comms_peer_link_attempts_total Admitted direct peer-link attempts.",
      "# TYPE k_comms_peer_link_attempts_total counter",
      "k_comms_peer_link_attempts_total #{value(:peer_link_attempt_total)}",
      "# HELP k_comms_peer_link_connections_total Established direct peer links by selected candidate class.",
      "# TYPE k_comms_peer_link_connections_total counter"
    ] ++
      Enum.map(@peer_link_candidate_classes, fn class ->
        "k_comms_peer_link_connections_total{candidate_class=\"#{class}\"} #{value({:peer_link_connection, class})}"
      end) ++
      [
        "# HELP k_comms_peer_link_fallbacks_total Direct peer links returned to the call service by reason class.",
        "# TYPE k_comms_peer_link_fallbacks_total counter"
      ] ++
      Enum.map(@peer_link_fallback_reasons, fn reason ->
        "k_comms_peer_link_fallbacks_total{reason=\"#{reason}\"} #{value({:peer_link_fallback, reason})}"
      end) ++
      [
        "# HELP k_comms_peer_link_connect_duration_seconds Admission-to-connected latency for direct peer links.",
        "# TYPE k_comms_peer_link_connect_duration_seconds histogram"
      ] ++
      Enum.map(@peer_link_buckets, fn bucket ->
        "k_comms_peer_link_connect_duration_seconds_bucket{le=\"#{bucket}\"} #{value({:peer_link_connect_bucket, bucket})}"
      end) ++
      [
        "k_comms_peer_link_connect_duration_seconds_bucket{le=\"+Inf\"} #{value(:peer_link_connect_count)}",
        "k_comms_peer_link_connect_duration_seconds_sum #{value(:peer_link_connect_sum_microseconds) / 1_000_000}",
        "k_comms_peer_link_connect_duration_seconds_count #{value(:peer_link_connect_count)}"
      ]
  end

  defp observe_peer_link_connect(duration) when is_number(duration) and duration >= 0 do
    increment(:peer_link_connect_count)
    add(:peer_link_connect_sum_microseconds, round(duration * 1_000_000))

    Enum.each(@peer_link_buckets, fn bucket ->
      if duration <= bucket, do: increment({:peer_link_connect_bucket, bucket})
    end)
  end

  defp observe_peer_link_connect(_duration), do: :ok

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
