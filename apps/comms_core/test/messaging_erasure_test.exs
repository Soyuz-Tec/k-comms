defmodule CommsCore.MessagingErasureTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :messaging
  @moduletag :governance

  import CommsCore.MessagingFixtures

  alias CommsCore.Attachments
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Messaging
  alias CommsCore.Messaging.{Message, MessageRevision, Reaction}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "content erasure owner APIs require a caller-owned transaction" do
    account = Fixtures.account_fixture()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:error, :transaction_required} =
             Messaging.tombstone_for_erasure(account.tenant.id, [], timestamp)

    assert {:error, :transaction_required} =
             Attachments.mark_deleted_for_erasure(account.tenant.id, [], timestamp)

    assert {:error, :transaction_required} =
             Messaging.delete_message(
               Ecto.UUID.generate(),
               Fixtures.subject(account),
               fn _candidate -> :ok end
             )
  end

  test "message erasure removes history and tombstones only tenant-owned messages" do
    account = Fixtures.account_fixture()
    other_account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    other_subject = Fixtures.subject(other_account)

    attrs =
      account
      |> message_attrs("message-erasure-owner", [])
      |> Map.put(:metadata, %{"sensitive" => true})

    assert {:ok, message} = Messaging.accept_message(attrs, subject)
    assert {:ok, _edited} = Messaging.edit_message(message.id, "updated sensitive body", subject)
    assert {:ok, _reaction} = Messaging.add_reaction(message.id, "👍", subject)

    assert {:ok, other_message} =
             other_account
             |> message_attrs("message-erasure-other", [])
             |> Messaging.accept_message(other_subject)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok,
            {:ok,
             %{
               messages_tombstoned: 0,
               revisions_deleted: 0,
               reactions_deleted: 0
             }}} =
             Repo.transaction(fn ->
               Messaging.tombstone_for_erasure(
                 other_account.tenant.id,
                 [message.id],
                 timestamp
               )
             end)

    assert {:ok,
            {:ok,
             %{
               messages_tombstoned: 1,
               revisions_deleted: 1,
               reactions_deleted: 1
             }}} =
             Repo.transaction(fn ->
               Messaging.tombstone_for_erasure(
                 account.tenant.id,
                 [message.id, other_message.id],
                 timestamp
               )
             end)

    tombstoned = Repo.get!(Message, message.id)
    assert tombstoned.status == :deleted
    assert tombstoned.body == nil
    assert tombstoned.metadata == %{}
    assert tombstoned.deleted_at == timestamp
    refute Repo.get_by(MessageRevision, message_id: message.id)
    refute Repo.get_by(Reaction, message_id: message.id)

    untouched = Repo.get!(Message, other_message.id)
    assert untouched.status == :active
    assert untouched.body == "message with attachment"
  end

  test "attachment erasure scrubs file identity only for tenant-owned attachments" do
    account = Fixtures.account_fixture()
    other_account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attachment = ready_attachment(subject, "d")
    other_attachment = ready_attachment(Fixtures.subject(other_account), "e")
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, {:ok, %{attachments_deleted: 0}}} =
             Repo.transaction(fn ->
               Attachments.mark_deleted_for_erasure(
                 other_account.tenant.id,
                 [attachment.id],
                 timestamp
               )
             end)

    assert {:ok, {:ok, %{attachments_deleted: 1}}} =
             Repo.transaction(fn ->
               Attachments.mark_deleted_for_erasure(
                 account.tenant.id,
                 [attachment.id, other_attachment.id],
                 timestamp
               )
             end)

    deleted = Repo.get!(Attachment, attachment.id)
    assert deleted.status == :deleted
    assert deleted.file_name == "deleted"
    assert deleted.content_type == "application/octet-stream"
    assert deleted.checksum_sha256 == nil
    assert deleted.updated_at == timestamp
    assert deleted.object_key == attachment.object_key
    assert deleted.object_version_id == attachment.object_version_id
    assert deleted.object_etag == attachment.object_etag
    assert deleted.verified_checksum_sha256 == attachment.verified_checksum_sha256

    untouched = Repo.get!(Attachment, other_attachment.id)
    assert untouched.status == :ready
    assert untouched.file_name == other_attachment.file_name
  end
end
