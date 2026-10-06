defmodule CommsCore.MigrationFixture do
  @moduledoc false

  # A finished migration subprocess has closed its sockets, but PostgreSQL may
  # not have consumed those closes yet. This only synchronizes owned test setup;
  # the production migration/rollback quiescence fences remain immediate.
  def await_no_peers(admin, database, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    observe(admin, database, deadline, nil)
  end

  defp observe(admin, database, deadline, last_count) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:peers_remain, last_count}}
    else
      result =
        Postgrex.query(
          admin,
          "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
          [database],
          timeout: remaining
        )

      case result do
        {:ok, %{rows: [[0]]}} ->
          if System.monotonic_time(:millisecond) < deadline,
            do: :ok,
            else: {:error, :observation_deadline_exceeded}

        {:ok, %{rows: [[count]]}} when is_integer(count) and count > 0 ->
          remaining = deadline - System.monotonic_time(:millisecond)
          if remaining > 0, do: Process.sleep(min(10, remaining))
          observe(admin, database, deadline, count)

        {:error, error} ->
          {:error, {:peer_observation_failed, error}}
      end
    end
  end
end
