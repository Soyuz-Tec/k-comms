defmodule CommsWorkers.NativePushReconcilerWorker do
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}),
    do: CommsCore.Notifications.reconcile_native_push(__MODULE__, args)
end
