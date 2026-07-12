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

  def render(queue_age_seconds \\ 0) do
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
      "k_comms_oban_queue_age_seconds #{queue_age_seconds}"
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
