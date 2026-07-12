defmodule CommsWorkers.NotificationWorker do
  use Oban.Worker, queue: :notifications, max_attempts: 10
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: CommsIntegrations.Notifications.deliver(args)
end
