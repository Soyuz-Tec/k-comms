defmodule CommsCore.AttachmentsFileListingTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Attachments
  alias CommsCore.Attachments.{Attachment, AttachmentView, FileView}
  alias CommsCore.Conversations
  alias CommsCore.Messaging
  alias CommsCore.Messaging.Message
  alias CommsTestSupport.Fixtures

  test "lists only authorized message-owned files with stable cursors and source facts" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    member = signed_in_member(account)

    assert {:ok, _membership} =
             Conversations.add_member(
               account.conversation.id,
               member.user.id,
               :member,
               owner_subject
             )

    owner_file = ready_attachment(owner_subject, "1")
    member_file = ready_attachment(member.subject, "2")

    assert {:ok, owner_message} =
             send_file(account.conversation.id, owner_subject, owner_file, "owner-file-message")

    assert {:ok, member_message} =
             send_file(
               account.conversation.id,
               member.subject,
               member_file,
               "member-file-message"
             )

    shared_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    from(message in Message, where: message.id in ^[owner_message.id, member_message.id])
    |> Repo.update_all(set: [inserted_at: shared_at])

    assert {:ok, first_page} =
             Attachments.list_files(owner_subject, %{scope: :recent, limit: 1})

    assert [%FileView{} = first] = first_page.files
    assert first_page.has_more
    assert is_binary(first_page.next_cursor)
    assert first.conversation_id == account.conversation.id
    assert first.message_id in [owner_message.id, member_message.id]

    assert first.conversation_sequence in [
             owner_message.conversation_sequence,
             member_message.conversation_sequence
           ]

    assert first.shared_at == shared_at
    assert first.safety_state == :available
    assert first.downloadable
    refute Map.has_key?(first, :object_key)
    refute Map.has_key?(first, :checksum_sha256)

    assert {:ok, second_page} =
             Attachments.list_files(owner_subject, %{
               scope: "recent",
               limit: "1",
               cursor: first_page.next_cursor
             })

    assert [%FileView{} = second] = second_page.files
    refute second_page.has_more
    assert second_page.next_cursor == nil
    assert MapSet.new([first.id, second.id]) == MapSet.new([owner_file.id, member_file.id])

    assert {:ok, shared_by_owner} =
             Attachments.list_files(owner_subject, %{scope: "shared_by_me"})

    assert Enum.map(shared_by_owner.files, & &1.id) == [owner_file.id]

    assert {:ok, conversation_files} =
             Attachments.list_files(owner_subject, %{conversation_id: account.conversation.id})

    assert MapSet.new(Enum.map(conversation_files.files, & &1.id)) ==
             MapSet.new([owner_file.id, member_file.id])

    other_account = Fixtures.account_fixture()
    other_subject = Fixtures.subject(other_account)

    assert {:ok, %{files: []}} = Attachments.list_files(other_subject)

    assert {:error, :forbidden} =
             Attachments.list_files(other_subject, %{
               conversation_id: account.conversation.id
             })
  end

  test "keeps unsafe files visible without making them downloadable and rejects bad filters" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attachment = ready_attachment(subject, "3")

    assert {:ok, _message} =
             send_file(account.conversation.id, subject, attachment, "blocked-file-message")

    from(value in Attachment, where: value.id == ^attachment.id)
    |> Repo.update_all(
      set: [
        status: :quarantined,
        scan_status: :blocked,
        quarantined_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ]
    )

    assert {:ok, %{files: [%FileView{} = file]}} = Attachments.list_files(subject)
    assert file.status == :quarantined
    assert file.scan_status == :blocked
    assert file.safety_state == :blocked
    refute file.downloadable

    assert {:error, :invalid_file_scope} =
             Attachments.list_files(subject, %{scope: "unknown"})

    assert {:error, :invalid_conversation_id} =
             Attachments.list_files(subject, %{conversation_id: "not-a-uuid"})

    assert {:error, :invalid_cursor} =
             Attachments.list_files(subject, %{cursor: "not-opaque"})

    assert {:error, :forbidden} =
             Attachments.list_files(Map.put(subject, :session_id, Ecto.UUID.generate()))
  end

  defp ready_attachment(subject, checksum_character) do
    checksum = String.duplicate(checksum_character, 64)

    assert {:ok, pending} =
             Attachments.create_intent(
               %{
                 file_name: "file-#{checksum_character}.txt",
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

  defp send_file(conversation_id, subject, attachment, client_message_id) do
    Messaging.accept_message(
      %{
        tenant_id: subject.tenant_id,
        conversation_id: conversation_id,
        sender_user_id: subject.user_id,
        sender_device_id: subject.device_id,
        client_message_id: client_message_id,
        body: "file",
        attachment_ids: [attachment.id]
      },
      subject
    )
  end

  defp signed_in_member(account) do
    member = Fixtures.user_fixture(account)
    [local, _domain] = String.split(member.user.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")

    assert {:ok, signed_in} =
             Accounts.authenticate_view(
               account.tenant.slug,
               member.user.email,
               "correct-horse-battery-#{suffix}",
               %{name: "Member browser", platform: "test"}
             )

    assert {:ok, access_context} = Accounts.access_context(signed_in.session_id)
    %{user: signed_in.user, subject: access_context.subject}
  end
end
