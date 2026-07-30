defmodule CommsCore.MessagingFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias CommsCore.Attachments
  alias CommsCore.Attachments.AttachmentView

  def ready_attachment(subject, checksum_character) do
    checksum = String.duplicate(checksum_character, 64)

    assert {:ok, pending} =
             Attachments.create_intent(
               %{
                 file_name: "ready-#{checksum_character}.txt",
                 content_type: "text/plain",
                 byte_size: 12,
                 checksum_sha256: checksum
               },
               subject
             )

    assert {:ok, uploaded} =
             Attachments.mark_uploaded(
               pending.id,
               checksum,
               %{
                 object_version_id: "version-#{checksum_character}",
                 object_etag: "etag-#{checksum_character}",
                 verified_checksum_sha256: checksum
               },
               subject
             )

    assert {:ok, scanning} = Attachments.claim_scan(uploaded.id)

    assert {:ok, %AttachmentView{} = ready} =
             Attachments.record_scan(
               scanning,
               {:ok, %{verdict: :clean, provider: "test"}}
             )

    ready
  end

  def message_attrs(account, client_message_id, attachment_ids) do
    %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: client_message_id,
      body: "message with attachment",
      attachment_ids: attachment_ids
    }
  end
end
