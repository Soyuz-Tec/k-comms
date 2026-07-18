defmodule CommsWorkers.WorkerTest do
  use ExUnit.Case, async: true

  test "attachment worker fails closed",
    do: assert({:discard, _} = CommsWorkers.AttachmentWorker.perform(%Oban.Job{args: %{}}))

  test "outbox worker rejects jobs without an event id" do
    assert {:discard, :event_id_required} =
             CommsWorkers.OutboxWorker.perform(%Oban.Job{args: %{}})
  end

  test "delivery workers reject jobs without durable ledger identifiers" do
    assert {:discard, :intent_id_required} =
             CommsWorkers.NotificationWorker.perform(%Oban.Job{args: %{}})

    assert {:discard, :delivery_id_required} =
             CommsWorkers.WebhookWorker.perform(%Oban.Job{args: %{}})
  end
end
