defmodule CommsCore.MessagingConcurrencyTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :messaging
  @moduletag :concurrency

  import CommsCore.MessagingFixtures

  alias CommsCore.Audit
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "concurrent retries return one canonical message and enqueue one outbox job" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: "concurrent-idempotency-message",
      body: "only once"
    }

    results =
      1..12
      |> Task.async_stream(
        fn _ -> Messaging.accept_message_with_status(attrs, subject) end,
        max_concurrency: 12,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :duplicate}, &1)) == 11

    ids = Enum.map(results, fn {:ok, message, _status} -> message.id end)
    assert [_canonical_id] = Enum.uniq(ids)

    assert 1 ==
             Message
             |> where(
               [message],
               message.tenant_id == ^account.tenant.id and
                 message.sender_device_id == ^account.device.id and
                 message.client_message_id == ^attrs.client_message_id
             )
             |> Repo.aggregate(:count)

    assert %OutboxEvent{} =
             outbox =
             Repo.get_by(OutboxEvent,
               tenant_id: account.tenant.id,
               aggregate_type: "message",
               event_type: "message.created.v1"
             )

    assert %Oban.Job{} =
             Repo.get_by(Oban.Job,
               worker: "CommsWorkers.OutboxWorker",
               args: %{"event_id" => outbox.id, "tenant_id" => account.tenant.id}
             )

    assert 1 == Audit.count(%{tenant_id: account.tenant.id, action: "message.created"})
  end

  test "concurrent distinct messages receive contiguous owner-reserved sequences" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    sequences =
      1..8
      |> Task.async_stream(
        fn index ->
          account
          |> message_attrs("owner-reserved-sequence-#{index}", [])
          |> Map.put(:body, "message #{index}")
          |> Messaging.accept_message(subject)
        end,
        max_concurrency: 8,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, {:ok, message}} -> message.conversation_sequence end)
      |> Enum.sort()

    assert sequences == Enum.to_list(1..8)
  end
end
