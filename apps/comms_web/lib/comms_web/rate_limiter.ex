defmodule CommsWeb.RateLimiter do
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def allow?(key, limit, window_seconds) do
    now = System.system_time(:second)
    bucket = div(now, window_seconds)

    count =
      :ets.update_counter(
        @table,
        {key, bucket},
        {2, 1},
        {{key, bucket}, 0, now + window_seconds * 2}
      )

    count <= limit
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 60_000)
end
