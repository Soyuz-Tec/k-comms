defmodule CommsCore.MessagingTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.Membership
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "accepts messages idempotently and orders them within a conversation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    conversation_id = account.conversation.id

    attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: conversation_id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: "client-message-0001",
      body: "hello"
    }

    assert {:ok, first, :created} = Messaging.accept_message_with_status(attrs, subject)
    assert {:ok, duplicate, :duplicate} = Messaging.accept_message_with_status(attrs, subject)
    assert first.id == duplicate.id
    assert first.conversation_sequence == 1

    assert {:ok, second} =
             Messaging.accept_message(
               %{attrs | client_message_id: "client-message-0002", body: "world"},
               subject
             )

    assert second.conversation_sequence == 2
    assert [^first, ^second] = Messaging.list_after(account.tenant.id, conversation_id)
  end

  test "validates message bodies, metadata, and attachment identifiers at the boundary" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: "validated-message-command",
      body: "valid body"
    }

    metadata = Map.new(1..33, fn index -> {Integer.to_string(index), index} end)

    assert {:error, :metadata_too_many_properties} =
             attrs
             |> Map.put(:metadata, metadata)
             |> Messaging.accept_message(subject)

    assert {:error, :metadata_too_large} =
             attrs
             |> Map.put(:metadata, %{"value" => String.duplicate("x", 65_537)})
             |> Messaging.accept_message(subject)

    attachment_id = Ecto.UUID.generate()

    assert {:error, :duplicate_attachment_ids} =
             attrs
             |> Map.put(:attachment_ids, [attachment_id, attachment_id])
             |> Messaging.accept_message(subject)

    assert {:error, :invalid_attachment_id} =
             attrs
             |> Map.put(:attachment_ids, ["not-a-uuid"])
             |> Messaging.accept_message(subject)

    assert {:error, :invalid_reply_target} =
             attrs
             |> Map.put(:reply_to_message_id, "not-a-uuid")
             |> Messaging.accept_message(subject)
  end

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
               args: %{"event_id" => outbox.id}
             )

    assert 1 ==
             AuditEvent
             |> where(
               [event],
               event.tenant_id == ^account.tenant.id and event.action == "message.created"
             )
             |> Repo.aggregate(:count)
  end

  test "edits, searches, reacts to, and deletes a message" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: "client-message-edit-1",
      body: "searchable original"
    }

    assert {:ok, message} = Messaging.accept_message(attrs, subject)
    assert {:error, :message_body_required} = Messaging.edit_message(message.id, "   ", subject)

    assert {:error, :message_too_large} =
             Messaging.edit_message(message.id, String.duplicate("x", 65_536), subject)

    assert {:ok, edited} = Messaging.edit_message(message.id, "searchable updated", subject)
    assert edited.edited_at
    assert {:ok, reaction} = Messaging.add_reaction(message.id, "👍", subject)
    assert reaction.emoji == "👍"

    membership =
      Repo.get_by!(Membership,
        conversation_id: account.conversation.id,
        user_id: account.user.id
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    membership |> Membership.changeset(%{left_at: now}) |> Repo.update!()
    assert {:error, :forbidden} = Messaging.remove_reaction(message.id, "👍", subject)

    Repo.get!(Membership, membership.id)
    |> Membership.changeset(%{left_at: nil})
    |> Repo.update!()

    assert :ok = Messaging.remove_reaction(message.id, "👍", subject)

    assert {:ok, results} = Messaging.search("updated", subject)
    assert Enum.any?(results, &(&1.id == message.id))
    assert {:ok, deleted} = Messaging.delete_message(message.id, subject)
    assert deleted.status == :deleted
    assert is_nil(deleted.body)
  end
end
