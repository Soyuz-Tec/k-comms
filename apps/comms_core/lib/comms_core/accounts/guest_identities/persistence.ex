defmodule CommsCore.Accounts.GuestIdentities.Persistence do
  @moduledoc false

  alias CommsCore.Repo

  def run_transaction_aware(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      fun.()
    else
      case Repo.transaction(fn ->
             case fun.() do
               {:error, reason} -> Repo.rollback(reason)
               result -> result
             end
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def audit_or_rollback({:ok, event}), do: event
  def audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
