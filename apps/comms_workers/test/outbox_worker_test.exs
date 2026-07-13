defmodule CommsWorkers.OutboxWorkerTest.FailingAvailabilityNotifier do
  def notify(_intent), do: {:error, :forced_availability_failure}
end

defmodule CommsWorkers.OutboxWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Conversations
  alias CommsCore.Events.OutboxEvent
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

    published = Repo.get!(OutboxEvent, event.id)
    assert published.published_at
    assert published.attempts == 1
  end

  test "does not republish a completed event" do
    account = Fixtures.account_fixture()
    published_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    event = outbox_event(account.tenant.id, published_at: published_at, attempts: 3)

    assert :ok = OutboxWorker.perform(%Oban.Job{args: %{"event_id" => event.id}})

    persisted = Repo.get!(OutboxEvent, event.id)
    assert persisted.published_at == published_at
    assert persisted.attempts == 3
  end

  test "records one attempt and leaves the event pending when delivery fanout fails" do
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

    Application.put_env(
      :comms_core,
      :notification_availability_notifier,
      CommsWorkers.OutboxWorkerTest.FailingAvailabilityNotifier
    )

    on_exit(fn ->
      Application.put_env(
        :comms_core,
        :notification_availability_notifier,
        previous_notifier
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

    persisted = Repo.get!(OutboxEvent, event.id)
    assert persisted.attempts == 1
    assert is_nil(persisted.published_at)
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

    %OutboxEvent{}
    |> OutboxEvent.changeset(attrs)
    |> Repo.insert!()
  end
end
