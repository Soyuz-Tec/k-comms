defmodule CommsCore.Messaging.PrivateBudget do
  @moduledoc false
  alias CommsCore.Repo
  def new, do: System.monotonic_time(:millisecond) + 15_000
  def remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  def check!(deadline) do
    if remaining(deadline) <= 0, do: Repo.rollback(:private_operation_timeout)
    :ok
  end

  def prepare!(deadline) do
    check!(deadline)
    timeout = Integer.to_string(remaining(deadline)) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    check!(deadline)
  end

  def authority(deadline, %{effective_expires_at: %DateTime{} = expires}) do
    min(
      deadline,
      System.monotonic_time(:millisecond) +
        max(0, DateTime.diff(expires, DateTime.utc_now(), :millisecond))
    )
  end

  def authority(_deadline, _grant), do: Repo.rollback(:forbidden)

  def transaction(deadline, operation) do
    if remaining(deadline) <= 0 do
      {:error, :private_operation_timeout}
    else
      Repo.transaction(
        fn ->
          prepare!(deadline)
          result = operation.()
          check!(deadline)
          result
        end,
        timeout: remaining(deadline)
      )
    end
  rescue
    _error in DBConnection.ConnectionError ->
      {:error, :private_operation_timeout}

    error in Postgrex.Error ->
      if error.postgres[:code] in [:query_canceled, :lock_not_available],
        do: {:error, :private_operation_timeout},
        else: reraise(error, __STACKTRACE__)
  end
end
