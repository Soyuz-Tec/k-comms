defmodule CommsWorkers.NativeCallWakeWorker do
  use Oban.Worker, queue: :notifications, max_attempts: 3
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"wake_id" => id, "registration_version" => version}}) do
    case CommsCore.Notifications.dispatch_native_call_wake(id, version, __MODULE__) do
      {:ok, _} -> :ok
      _ -> {:discard, :native_push_unavailable}
    end
  end
  def perform(_), do: {:discard, :native_push_unavailable}
end
