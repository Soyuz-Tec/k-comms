defmodule CommsWeb.RateLimiter do
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def allow?(key, limit, window_seconds) do
    allow_at(key, limit, window_seconds, System.monotonic_time(:second))
  end

  if Mix.env() == :test do
    @doc false
    def reset, do: :ets.delete_all_objects(@table)

    @doc false
    def allow_at?(key, limit, window_seconds, now),
      do: allow_at(key, limit, window_seconds, now)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp allow_at(key, limit, window_seconds, now) do
    expires_at = now + window_seconds

    if :ets.insert_new(@table, {key, 1, expires_at}) do
      1 <= limit
    else
      update_existing(key, limit, window_seconds, now)
    end
  end

  defp update_existing(key, limit, window_seconds, now) do
    case :ets.lookup(@table, key) do
      [] ->
        allow_at(key, limit, window_seconds, now)

      [{^key, count, expires_at}] ->
        {next_count, next_expires_at} =
          if now >= expires_at do
            {1, now + window_seconds}
          else
            {count + 1, expires_at}
          end

        match_spec = [
          {{:"$1", count, expires_at}, [{:==, :"$1", {:const, key}}],
           [{{:"$1", next_count, next_expires_at}}]}
        ]

        if :ets.select_replace(@table, match_spec) == 1 do
          next_count <= limit
        else
          update_existing(key, limit, window_seconds, now)
        end
    end
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 60_000)
end
