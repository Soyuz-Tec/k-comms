defmodule CommsCore.MessagingTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Administration, Attachments, Governance}
  alias CommsCore.Attachments.{Attachment, AttachmentView}
  alias CommsCore.Audit
  alias CommsCore.Conversations
  alias CommsCore.Conversations.Membership
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging
  alias CommsCore.Messaging.{Message, MessageRevision, MessageView, Reaction}
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

  test "publishes a ready attachment through views and rejects a second claim atomically" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    attachment = ready_attachment(account, "c")

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
    foreign_attachment = ready_attachment(other_account, "e")

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
    assert {:ok, deleted} = Governance.delete_message(message.id, subject)
    assert deleted.status == :deleted
    assert is_nil(deleted.body)
  end

  test "search returns active conversation messages and excludes archived conversations" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "archived-search-message",
                 body: "archived search boundary token"
               },
               subject
             )

    assert {:ok, active_results} = Messaging.search("boundary token", subject)
    assert Enum.any?(active_results, &(&1.id == message.id))

    assert {:ok, _archived} =
             Conversations.archive(
               account.conversation.id,
               %{version: account.conversation.lock_version},
               subject
             )

    assert {:ok, archived_results} = Messaging.search("boundary token", subject)
    refute Enum.any?(archived_results, &(&1.id == message.id))
  end

  test "search pages authorized results with server-side filters and opaque cursors" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, second_conversation} =
             Conversations.create(
               %{
                 title: "Search filters",
                 kind: "group",
                 visibility: "private",
                 member_ids: []
               },
               subject
             )

    message_attrs = %{
      tenant_id: account.tenant.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      body: "roadmap pagination token"
    }

    assert {:ok, first} =
             Messaging.accept_message(
               Map.merge(message_attrs, %{
                 conversation_id: account.conversation.id,
                 client_message_id: "search-page-first"
               }),
               subject
             )

    assert {:ok, second} =
             Messaging.accept_message(
               Map.merge(message_attrs, %{
                 conversation_id: second_conversation.id,
                 client_message_id: "search-page-second"
               }),
               subject
             )

    assert {:ok, page_one} = Messaging.search_page("roadmap", subject, limit: 1)
    assert page_one.limit == 1
    assert page_one.has_more
    assert is_binary(page_one.next_cursor)
    assert length(page_one.messages) == 1

    assert {:ok, page_two} =
             Messaging.search_page("roadmap", subject, limit: 1, cursor: page_one.next_cursor)

    refute page_two.has_more
    assert page_two.next_cursor == nil

    assert MapSet.new(Enum.map(page_one.messages ++ page_two.messages, & &1.id)) ==
             MapSet.new([first.id, second.id])

    assert {:ok, filtered} =
             Messaging.search_page("roadmap", subject,
               conversation_id: second_conversation.id,
               sender_user_id: account.user.id,
               after: second.inserted_at
             )

    assert Enum.map(filtered.messages, & &1.id) == [second.id]

    assert {:ok, no_sender_match} =
             Messaging.search_page("roadmap", subject, sender_user_id: Ecto.UUID.generate())

    assert no_sender_match.messages == []

    assert {:error, :invalid_cursor} =
             Messaging.search_page("roadmap", subject, cursor: "invalid")

    assert {:error, :invalid_search_query} =
             Messaging.search_page("roadmap", subject, conversation_id: "not-a-uuid")
  end

  test "tenant edit-window policy is enforced for message authors" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "edit-window-policy-message",
                 body: "immutable after policy change"
               },
               subject
             )

    assert {:ok, _settings} =
             Administration.update_tenant_settings(
               %{version: 1, message_edit_window_seconds: 0},
               subject
             )

    assert {:error, :edit_window_expired} =
             Messaging.edit_message(message.id, "must be rejected", subject)
  end

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
    attachment = ready_attachment(account, "d")
    other_attachment = ready_attachment(other_account, "e")
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

  defp ready_attachment(account, checksum_character) do
    subject = Fixtures.subject(account)
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

  defp message_attrs(account, client_message_id, attachment_ids) do
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
