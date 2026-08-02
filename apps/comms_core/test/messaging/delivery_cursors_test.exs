defmodule CommsCore.Messaging.DeliveryCursorsTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :messaging

  alias CommsCore.Messaging
  alias CommsTestSupport.Fixtures

  test "delivery and read cursors are monotonic, bounded, and scoped to a device" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    for sequence <- 1..3 do
      assert {:ok, message} =
               Messaging.accept_message(
                 %{
                   tenant_id: account.tenant.id,
                   conversation_id: account.conversation.id,
                   sender_user_id: account.user.id,
                   sender_device_id: account.device.id,
                   client_message_id: "delivery-cursor-#{sequence}",
                   body: "message #{sequence}"
                 },
                 subject
               )

      assert message.conversation_sequence == sequence
    end

    assert {:ok, delivered} = Messaging.mark_delivered(account.conversation.id, 99, subject)
    assert delivered.delivered_sequence == 3
    assert delivered.read_sequence == 0

    assert {:ok, read} = Messaging.mark_read(account.conversation.id, 2, subject)
    assert read.delivered_sequence == 3
    assert read.read_sequence == 2

    assert {:ok, unchanged} = Messaging.mark_read(account.conversation.id, 1, subject)
    assert unchanged.delivered_sequence == 3
    assert unchanged.read_sequence == 2

    assert {:ok, [cursor]} = Messaging.list_delivery_cursors(account.conversation.id, subject)
    assert cursor.device_ref == unchanged.device_ref
    refute cursor.device_ref == account.device.id
  end

  test "invalid and unauthorized cursor updates fail closed" do
    account = Fixtures.account_fixture()
    outsider = Fixtures.account_fixture()

    assert {:error, :invalid_sequence} =
             Messaging.mark_delivered(
               account.conversation.id,
               -1,
               Fixtures.subject(account)
             )

    assert {:error, :forbidden} =
             Messaging.mark_delivered(
               account.conversation.id,
               1,
               Fixtures.subject(outsider)
             )
  end
end
