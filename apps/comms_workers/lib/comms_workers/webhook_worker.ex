defmodule CommsWorkers.WebhookWorker do
  use Oban.Worker, queue: :webhooks, max_attempts: 12
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: CommsIntegrations.Webhooks.deliver(args)
end
