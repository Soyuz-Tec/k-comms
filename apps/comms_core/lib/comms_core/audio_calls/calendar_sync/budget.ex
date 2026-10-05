defmodule CommsCore.AudioCalls.CalendarSync.Budget do
  @moduledoc false
  alias CommsCore.Repo
  def deadline, do: System.monotonic_time(:millisecond) + 15_000
  def network_deadline(deadline), do: min(deadline, System.monotonic_time(:millisecond) + 5_000)

  def check!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:calendar_authority_expired)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout',$1,true), set_config('statement_timeout',$1,true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline,
      do: Repo.rollback(:calendar_authority_expired)

    :ok
  end

  def transaction(operation),
    do: Repo.transaction(fn -> operation.(deadline()) end, timeout: 20_000)

  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
