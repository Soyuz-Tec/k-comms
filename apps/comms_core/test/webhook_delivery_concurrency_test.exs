defmodule CommsCore.WebhookDeliveryConcurrencyTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Integrations, Outbox, Repo}
  alias CommsCore.Integrations.WebhookDelivery
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :webhook
  @moduletag :concurrency

  test "fanout cannot insert a pre-change delivery after destination discovery" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    {:ok, %{endpoint: endpoint}} = create_endpoint(subject, "Fanout destination race")
    event = insert_outbox_event!(account, "bound-to-original-destination")
    parent = self()
    handler_id = {__MODULE__, :fanout_destination_race, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 query = Map.get(metadata, :query, "")

                 if String.contains?(query, ~s(FROM "webhook_endpoints")) and
                      String.contains?(query, ~s(JOIN "webhook_subscriptions")) do
                   caller = self()
                   send(test_pid, {:fanout_destination_discovered, caller})

                   receive do
                     {:continue_fanout, ^test_pid} -> :ok
                   after
                     5_000 -> exit(:fanout_destination_barrier_timeout)
                   end
                 end
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    enqueue_task = Task.async(fn -> Integrations.enqueue_for_event(event) end)
    assert_receive {:fanout_destination_discovered, enqueue_pid}, 5_000

    assert {:ok, changed} =
             Integrations.update_endpoint(
               endpoint.id,
               %{url: "https://hooks.example.test/replacement"},
               subject
             )

    assert changed.url == "https://hooks.example.test/replacement"
    send(enqueue_pid, {:continue_fanout, parent})
    assert :ok = Task.await(enqueue_task, 5_000)

    terminal = Repo.get_by!(WebhookDelivery, outbox_event_id: event.id)
    assert terminal.status == :failed
    assert terminal.last_error_code == "endpoint_configuration_changed"
    assert {:error, :terminal_delivery} = Integrations.claim_delivery(terminal.id)

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "CommsWorkers.WebhookWorker" and
                   fragment("?->>'delivery_id' = ?", job.args, ^terminal.id)
             )
           )

    assert :ok = :telemetry.detach(handler_id)
    assert :ok = Integrations.enqueue_for_event(event)
    assert Repo.aggregate(WebhookDelivery, :count) == 1
    assert Repo.get!(WebhookDelivery, terminal.id).status == :failed

    assert {:ok, replayed} = Integrations.replay_delivery(terminal.id, subject)
    assert {:ok, claimed} = Integrations.claim_delivery(replayed.id)

    assert {:ok, %{url: "https://hooks.example.test/replacement"}} =
             Integrations.delivery_request(claimed)
  end

  test "replay holds the endpoint lock until its delivery is visible to destination updates" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    {:ok, %{endpoint: endpoint}} = create_endpoint(subject, "Replay destination race")

    {:ok, source} =
      Integrations.create_delivery(%{
        tenant_id: account.tenant.id,
        endpoint_id: endpoint.id,
        event_type: "message.created.v1",
        payload: %{"sensitive" => "replay-only-to-locked-destination"},
        idempotency_key: "webhook-replay-destination-race-source",
        secret_version: endpoint.secret_version,
        status: :pending,
        next_attempt_at: DateTime.utc_now()
      })

    parent = self()
    handler_id = {__MODULE__, :replay_destination_race, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, %{handler_id: id, parent: test_pid} ->
                 query = Map.get(metadata, :query, "")

                 if String.contains?(query, ~s(FROM "webhook_endpoints")) and
                      String.contains?(query, "FOR UPDATE") do
                   :telemetry.detach(id)
                   caller = self()
                   send(test_pid, {:replay_endpoint_locked, caller})

                   receive do
                     {:continue_replay, ^test_pid} -> :ok
                   after
                     5_000 -> exit(:replay_destination_barrier_timeout)
                   end
                 end
               end,
               %{handler_id: handler_id, parent: parent}
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    replay_task = Task.async(fn -> Integrations.replay_delivery(source.id, subject) end)
    assert_receive {:replay_endpoint_locked, replay_pid}, 5_000

    update_task =
      Task.async(fn ->
        Integrations.update_endpoint(
          endpoint.id,
          %{url: "https://hooks.example.test/replacement"},
          subject
        )
      end)

    assert Task.yield(update_task, 100) == nil
    send(replay_pid, {:continue_replay, parent})

    assert {:ok, replayed} = Task.await(replay_task, 5_000)
    assert {:ok, changed} = Task.await(update_task, 5_000)
    assert changed.url == "https://hooks.example.test/replacement"

    terminal = Repo.get!(WebhookDelivery, replayed.id)
    assert terminal.status == :failed
    assert terminal.last_error_code == "endpoint_configuration_changed"
  end

  defp create_endpoint(subject, name) do
    Integrations.create_endpoint(
      %{
        name: name,
        url: "https://hooks.example.test/original",
        event_types: ["message.created.v1"]
      },
      subject
    )
  end

  defp insert_outbox_event!(account, sensitive) do
    attrs = %{
      tenant_id: account.tenant.id,
      event_type: "message.created.v1",
      aggregate_type: "message",
      aggregate_id: Ecto.UUID.generate(),
      payload: %{"sensitive" => sensitive},
      available_at: DateTime.utc_now()
    }

    {:ok, event} = Repo.transaction(fn -> Outbox.insert_and_enqueue!(attrs) end)
    event
  end
end
