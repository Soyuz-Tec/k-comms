defmodule CommsCore.MessagingAcceptanceTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :messaging

  alias CommsCore.Messaging
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

  test "failed validation after sequence reservation does not consume a sequence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: "invalid-mention-before-message",
      body: "invalid mention",
      mentioned_user_ids: [Ecto.UUID.generate()]
    }

    assert {:error, :invalid_mentions} = Messaging.accept_message(attrs, subject)

    assert {:ok, message} =
             attrs
             |> Map.merge(%{
               client_message_id: "valid-message-after-invalid-mention",
               body: "valid message",
               mentioned_user_ids: []
             })
             |> Messaging.accept_message(subject)

    assert message.conversation_sequence == 1
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
end
