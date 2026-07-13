defmodule CommsCore.OutboxTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Outbox
  alias CommsCore.Repo
  alias CommsCore.RuntimePorts
  alias CommsTestSupport.Fixtures

  test "owns publication state and attempt persistence for worker adapters" do
    account = Fixtures.account_fixture()
    event = outbox_event(account.tenant.id)
    worker = RuntimePorts.job_worker!(:outbox_publication)

    assert {:ok, fetched} = Outbox.fetch_for_publication(event.id, worker)
    assert fetched.id == event.id
    assert fetched.attempts == 0

    assert :ok = Outbox.record_attempt(event.id, worker)
    assert Repo.get!(OutboxEvent, event.id).attempts == 1

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
    %OutboxEvent{}
    |> OutboxEvent.changeset(%{
      tenant_id: tenant_id,
      event_type: "outbox.boundary.test.v1",
      aggregate_type: "test",
      aggregate_id: Ecto.UUID.generate(),
      payload: %{},
      available_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
