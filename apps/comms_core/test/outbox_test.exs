defmodule CommsCore.OutboxTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Outbox
  alias CommsCore.Outbox.Event
  alias CommsCore.Repo
  alias CommsCore.RuntimePorts
  alias CommsTestSupport.Fixtures

  @attempt_recorded_event [:k_comms, :outbox, :attempt, :recorded]

  test "requires an explicit transaction and rolls back the event with its publication job" do
    account = Fixtures.account_fixture()
    attrs = outbox_attrs(account.tenant.id)
    event_count = Repo.aggregate(OutboxEvent, :count)
    job_count = Repo.aggregate(Oban.Job, :count)

    assert_raise ArgumentError,
                 "CommsCore.Outbox.insert_and_enqueue!/1 requires an active owner transaction",
                 fn -> Outbox.insert_and_enqueue!(attrs) end

    assert Repo.aggregate(OutboxEvent, :count) == event_count
    assert Repo.aggregate(Oban.Job, :count) == job_count

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               event = Outbox.insert_and_enqueue!(attrs)

               assert Repo.aggregate(OutboxEvent, :count) == event_count + 1
               assert Repo.aggregate(Oban.Job, :count) == job_count + 1
               assert Repo.get!(OutboxEvent, event.id)

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.aggregate(OutboxEvent, :count) == event_count
    assert Repo.aggregate(Oban.Job, :count) == job_count
  end

  test "owns publication state and attempt persistence for worker adapters" do
    account = Fixtures.account_fixture()
    event = outbox_event(account.tenant.id)
    worker = RuntimePorts.job_worker!(:outbox_publication)
    attach_attempt_handler()

    assert {:ok, fetched} = Outbox.fetch_for_publication(event.id, worker)
    assert %Event{id: event_id} = fetched
    assert event_id == event.id
    refute Map.has_key?(fetched, :attempts)
    refute inspect(fetched) =~ "payload"

    assert :ok = Outbox.record_attempt(event.id, worker)
    assert Repo.get!(OutboxEvent, event.id).attempts == 1

    assert_receive {@attempt_recorded_event, %{count: 1}, %{event_id: event_id}}

    assert event_id == event.id

    assert :ok = Outbox.mark_published(event.id, worker)

    published = Repo.get!(OutboxEvent, event.id)
    assert published.published_at
    assert published.attempts == 2
    assert :already_published = Outbox.fetch_for_publication(event.id, worker)

    assert :ok = Outbox.mark_published(event.id, worker)
    assert Repo.get!(OutboxEvent, event.id).attempts == 2
  end

  test "reports a missing publication event without exposing persistence to workers" do
    worker = RuntimePorts.job_worker!(:outbox_publication)

    assert :not_found = Outbox.fetch_for_publication(Ecto.UUID.generate(), worker)
  end

  test "does not report an attempt when no durable event was incremented" do
    worker = RuntimePorts.job_worker!(:outbox_publication)
    attach_attempt_handler()

    assert :ok = Outbox.record_attempt(Ecto.UUID.generate(), worker)
    refute_receive {@attempt_recorded_event, _, _}
  end

  test "rejects unauthorized publication access without changing durable state" do
    account = Fixtures.account_fixture()
    event = outbox_event(account.tenant.id)

    assert {:error, :forbidden} = Outbox.fetch_for_publication(event.id, __MODULE__)
    assert {:error, :forbidden} = Outbox.record_attempt(event.id, __MODULE__)
    assert {:error, :forbidden} = Outbox.mark_published(event.id, __MODULE__)

    persisted = Repo.get!(OutboxEvent, event.id)
    assert persisted.attempts == 0
    assert is_nil(persisted.published_at)
  end

  defp outbox_event(tenant_id) do
    {:ok, event} =
      Repo.transaction(fn ->
        Outbox.insert_and_enqueue!(outbox_attrs(tenant_id))
      end)

    event
  end

  defp outbox_attrs(tenant_id) do
    %{
      tenant_id: tenant_id,
      event_type: "outbox.boundary.test.v1",
      aggregate_type: "test",
      aggregate_id: Ecto.UUID.generate(),
      payload: %{},
      available_at: DateTime.utc_now()
    }
  end

  defp attach_attempt_handler do
    handler_id = {__MODULE__, :attempt_recorded, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @attempt_recorded_event,
        fn event_name, measurements, metadata, test_pid ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
