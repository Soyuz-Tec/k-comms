defmodule CommsCore.MessagingHistoryTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :messaging

  alias CommsCore.Accounts.Device
  alias CommsCore.Messaging
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "history pages opt in to one batched sender-label sidecar after slicing" do
    account = Fixtures.account_fixture(%{display_name: "History Author"})
    subject = Fixtures.subject(account)

    base_attrs = %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      body: "retained history"
    }

    assert {:ok, first} =
             base_attrs
             |> Map.put(:client_message_id, "history-sidecar-message-0001")
             |> Messaging.accept_message(subject)

    assert {:ok, _second} =
             base_attrs
             |> Map.put(:client_message_id, "history-sidecar-message-0002")
             |> Messaging.accept_message(subject)

    assert {:ok, page} =
             Messaging.list_history_page(account.conversation.id, subject,
               after_sequence: 0,
               limit: 1,
               include_sender_labels: true
             )

    assert Enum.map(page.messages, & &1.id) == [first.id]
    assert page.has_more
    assert page.next_after_sequence == first.conversation_sequence

    assert [
             %CommsCore.Accounts.RetainedSenderLabelView{
               id: sender_id,
               display_name: "History Author"
             }
           ] = page.sender_labels

    assert sender_id == account.user.id

    assert {:ok, default_page} =
             Messaging.list_history_page(account.conversation.id, subject,
               after_sequence: 0,
               limit: 1
             )

    assert default_page.sender_labels == []
  end

  test "sender-label refresh derives authors from exact authorized message IDs beyond 200 messages" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    old_author = Fixtures.user_fixture(account, %{display_name: "Old Visible Author"}).user

    old_author_device =
      %Device{}
      |> Device.changeset(%{
        tenant_id: account.tenant.id,
        user_id: old_author.id,
        name: "Old author browser",
        platform: "test"
      })
      |> Repo.insert!()

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..201, fn sequence ->
        old_author_message? = sequence == 1

        %{
          id: Ecto.UUID.generate(),
          tenant_id: account.tenant.id,
          conversation_id: account.conversation.id,
          sender_user_id: if(old_author_message?, do: old_author.id, else: account.user.id),
          sender_device_id:
            if(old_author_message?, do: old_author_device.id, else: account.device.id),
          client_message_id: "sender-label-refresh-#{sequence}",
          conversation_sequence: sequence,
          body: "Rendered message #{sequence}",
          metadata: %{},
          status: :active,
          inserted_at: inserted_at
        }
      end)

    assert {201, nil} = Repo.insert_all(Message, rows)
    old_message_id = rows |> hd() |> Map.fetch!(:id)
    newer_message_id = rows |> Enum.at(1) |> Map.fetch!(:id)

    foreign = Fixtures.account_fixture(%{display_name: "Foreign Author"})

    assert {:ok, foreign_message} =
             Messaging.accept_message(
               %{
                 tenant_id: foreign.tenant.id,
                 conversation_id: foreign.conversation.id,
                 sender_user_id: foreign.user.id,
                 sender_device_id: foreign.device.id,
                 client_message_id: "foreign-sender-label-message",
                 body: "Foreign message"
               },
               Fixtures.subject(foreign)
             )

    non_author_id = Fixtures.user_fixture(account).user.id

    assert {:ok, labels} =
             Messaging.refresh_sender_labels(
               account.conversation.id,
               [old_message_id, foreign_message.id, non_author_id],
               subject
             )

    assert [
             %CommsCore.Accounts.RetainedSenderLabelView{
               id: author_id,
               display_name: "Old Visible Author",
               redacted: false
             }
           ] = labels

    assert author_id == old_author.id

    guest_subject =
      subject
      |> Map.put(:account_type, :guest)
      |> Map.put(:guest_history_from_sequence, 2)

    assert {:ok, guest_labels} =
             Messaging.refresh_sender_labels(
               account.conversation.id,
               [old_message_id, newer_message_id],
               guest_subject
             )

    assert Enum.map(guest_labels, & &1.id) == [account.user.id]

    assert {:error, :forbidden} =
             Messaging.refresh_sender_labels(
               account.conversation.id,
               [old_message_id],
               Fixtures.subject(foreign)
             )

    assert {:error, :invalid_message_ids} =
             Messaging.refresh_sender_labels(account.conversation.id, [], subject)

    assert {:error, :invalid_message_ids} =
             Messaging.refresh_sender_labels(
               account.conversation.id,
               [old_message_id, old_message_id],
               subject
             )

    assert {:error, :invalid_message_ids} =
             Messaging.refresh_sender_labels(
               account.conversation.id,
               ["not-a-uuid"],
               subject
             )

    assert {:error, :invalid_message_ids} =
             Messaging.refresh_sender_labels(
               account.conversation.id,
               Enum.map(1..201, fn _ -> Ecto.UUID.generate() end),
               subject
             )
  end
end
