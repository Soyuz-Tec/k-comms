defmodule CommsCore.Notifications.NativePushProviderPort do
  @moduledoc "One retained-transaction provider effect; status performs no network I/O."
  alias CommsCore.Notifications.NativeDelivery
  alias CommsCore.Repo
  @spec deliver(NativeDelivery.t(), integer()) :: :ok | {:error, atom()}
  def deliver(%NativeDelivery{} = delivery, deadline) do
    if Repo.in_transaction?(), do: invoke(:deliver, [delivery, deadline]), else: {:error, :transaction_required}
  end
  @spec status() :: map()
  def status() do
    case invoke(:status, []) do
      %{status: :available} = status -> %{status: :available, channels: Map.get(status, :channels, [])}
      _ -> %{status: :unavailable, channels: []}
    end
  end
  defp invoke(method, args) do
    with {:ok, adapter} <- Application.fetch_env(:comms_core, :native_push_provider_adapter),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, method, length(args)) do
      apply(adapter, method, args)
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
end
