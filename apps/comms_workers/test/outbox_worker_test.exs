defmodule CommsWorkers.OutboxWorkerTest.FailOnceAvailabilityNotifier do
  @behaviour CommsCore.Notifications.AvailabilityNotifier.Contract

  @impl true
  def notify(_availability) do
    tracker =
      Application.fetch_env!(
        :comms_core,
        :notification_availability_notifier_test_tracker
      )

    Agent.get_and_update(tracker, fn
      0 -> {{:error, :forced_availability_failure}, 1}
      attempt_count -> {:ok, attempt_count + 1}
    end)
  end
end

defmodule CommsWorkers.OutboxWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Conversations
  alias CommsCore.Notifications
  alias CommsCore.Outbox
  alias CommsCore.Outbox.Event
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.OutboxWorker

  test "discards a job whose durable event is missing" do
    assert {:discard, :event_not_found} =
             OutboxWorker.perform(%Oban.Job{args: %{"event_id" => Ecto.UUID.generate()}})
  end

  test "publishes a pending event through the core persistence boundary" do
    account = Fixtures.account_fixture()
    event = outbox_event(account.tenant.id)

    assert :ok = OutboxWorker.perform(%Oban.Job{args: %{"event_id" => event.id}})
    assert :already_published = Outbox.fetch_for_publication(event.id, OutboxWorker)
  end

  test "does not republish a completed event" do
    account = Fixtures.account_fixture()
    event = outbox_event(account.tenant.id)
    assert :ok = Outbox.mark_published(event.id, OutboxWorker)

    assert :ok = OutboxWorker.perform(%Oban.Job{args: %{"event_id" => event.id}})
    assert :already_published = Outbox.fetch_for_publication(event.id, OutboxWorker)
  end

  test "retries availability signaling for an idempotent intent and then publishes the event" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Outbox failure",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    previous_notifier =
      Application.fetch_env!(:comms_core, :notification_availability_notifier)

    tracker = start_supervised!({Agent, fn -> 0 end})
    telemetry_handler = {__MODULE__, :attempt_recorded, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:k_comms, :outbox, :attempt, :recorded],
        fn event_name, measurements, metadata, test_pid ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        self()
      )

    Application.put_env(
      :comms_core,
      :notification_availability_notifier,
      CommsWorkers.OutboxWorkerTest.FailOnceAvailabilityNotifier
    )

    Application.put_env(
      :comms_core,
      :notification_availability_notifier_test_tracker,
      tracker
    )

    on_exit(fn ->
      :telemetry.detach(telemetry_handler)

      Application.put_env(
        :comms_core,
        :notification_availability_notifier,
        previous_notifier
      )

      Application.delete_env(
        :comms_core,
        :notification_availability_notifier_test_tracker
      )
    end)

    event =
      outbox_event(account.tenant.id,
        event_type: "message.created.v1",
        aggregate_type: "message",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{
          "conversation_id" => conversation.id,
          "sender_user_id" => account.user.id,
          "mentioned_user_ids" => []
        }
      )

    assert {:error, :forced_availability_failure} =
             OutboxWorker.perform(%Oban.Job{args: %{"event_id" => event.id}})

    assert_receive {[:k_comms, :outbox, :attempt, :recorded], %{count: 1}, %{event_id: event_id}}

    assert event_id == event.id
    assert Agent.get(tracker, & &1) == 1

    assert {:ok, %Event{id: pending_event_id}} =
             Outbox.fetch_for_publication(event.id, OutboxWorker)

    assert pending_event_id == event.id

    assert :ok = OutboxWorker.perform(%Oban.Job{args: %{"event_id" => event.id}})
    assert Agent.get(tracker, & &1) == 2
    assert :already_published = Outbox.fetch_for_publication(event.id, OutboxWorker)

    assert {:ok, %{notifications: [_intent]}} =
             Notifications.list_in_app(%{
               tenant_id: account.tenant.id,
               user_id: member.user.id
             })
  end

  defp outbox_event(tenant_id, overrides \\ []) do
    attrs =
      %{
        tenant_id: tenant_id,
        event_type: "outbox.worker.test.v1",
        aggregate_type: "test",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{},
        available_at: DateTime.utc_now()
      }
      |> Map.merge(Map.new(overrides))

    {:ok, event} = Repo.transaction(fn -> Outbox.insert_and_enqueue!(attrs) end)
    event
  end
end
