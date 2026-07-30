defmodule CommsCore.MessagingAttachmentClaimsTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :messaging

  import CommsCore.MessagingFixtures

  alias CommsCore.Attachments
  alias CommsCore.Attachments.{Attachment, AttachmentView}
  alias CommsCore.Messaging
  alias CommsCore.Messaging.{Message, MessageView}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "publishes a ready attachment through views and rejects a second claim atomically" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attachment = ready_attachment(subject, "c")

    attrs = message_attrs(account, "attachment-claim-message-1", [attachment.id])

    assert {:ok, %MessageView{} = message} = Messaging.accept_message(attrs, subject)
    assert [%AttachmentView{id: attachment_id, message_id: message_id}] = message.attachments
    assert attachment_id == attachment.id
    assert message_id == message.id
    refute Map.has_key?(message, :__meta__)

    persisted_attachment = Repo.get!(Attachment, attachment.id)
    assert persisted_attachment.message_id == message.id

    assert {:error, :invalid_attachments} =
             account
             |> message_attrs("attachment-claim-message-2", [attachment.id])
             |> Messaging.accept_message(subject)

    refute Repo.get_by(Message,
             tenant_id: account.tenant.id,
             client_message_id: "attachment-claim-message-2"
           )
  end

  test "attachment claims require and remain part of the message transaction" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attachment = ready_attachment(subject, "8")
    client_message_id = "attachment-owner-contributed-transaction"

    assert {:error, :transaction_required} =
             Attachments.attach_ready(
               [],
               Ecto.UUID.generate(),
               account.tenant.id,
               subject
             )

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, message} =
                        account
                        |> message_attrs(client_message_id, [attachment.id])
                        |> Messaging.accept_message(subject)

               assert Repo.get!(Attachment, attachment.id).message_id == message.id
               Repo.rollback(:forced_rollback)
             end)

    assert Repo.get!(Attachment, attachment.id).message_id == nil

    refute Repo.get_by(Message,
             tenant_id: account.tenant.id,
             client_message_id: client_message_id
           )
  end

  test "rejects pending and foreign-tenant attachments without committing a message" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, pending} =
             Attachments.create_intent(
               %{
                 file_name: "pending.txt",
                 content_type: "text/plain",
                 byte_size: 7,
                 checksum_sha256: String.duplicate("d", 64)
               },
               subject
             )

    other_account = Fixtures.account_fixture()
    foreign_attachment = ready_attachment(Fixtures.subject(other_account), "e")

    for {client_message_id, attachment_id} <- [
          {"pending-attachment-message", pending.id},
          {"foreign-attachment-message", foreign_attachment.id}
        ] do
      assert {:error, :invalid_attachments} =
               account
               |> message_attrs(client_message_id, [attachment_id])
               |> Messaging.accept_message(subject)

      refute Repo.get_by(Message,
               tenant_id: account.tenant.id,
               client_message_id: client_message_id
             )
    end
  end
end
