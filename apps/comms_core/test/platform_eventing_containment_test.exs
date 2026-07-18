defmodule CommsCore.PlatformEventingContainmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Integrations.WebhookDelivery
  alias CommsCore.Outbox.Event

  test "the public outbox facade exposes only its stable event contract" do
    source =
      __DIR__
      |> Path.join("../lib/comms_core/outbox.ex")
      |> Path.expand()
      |> File.read!()

    assert source =~ "CommsCore.Events.OutboxStore"
    refute source =~ "OutboxEvent"
    refute source =~ "CommsCore.Repo"
    refute source =~ "Ecto.Query"
    refute source =~ "Oban.Job"
    refute function_exported?(Event, :__schema__, 1)
  end

  test "webhook delivery retains only the outbox event identifier" do
    assert WebhookDelivery.__schema__(:type, :outbox_event_id) == :binary_id
    refute :outbox_event in WebhookDelivery.__schema__(:associations)
  end
end
