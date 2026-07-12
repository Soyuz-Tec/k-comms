defmodule CommsWorkers.AttachmentWorker do
  use Oban.Worker, queue: :media, max_attempts: 5
  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}), do: {:discard, :attachment_processor_not_configured}
end
