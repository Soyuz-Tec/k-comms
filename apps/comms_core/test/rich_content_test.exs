defmodule CommsCore.RichContentTest do
  use CommsCore.DataCase, async: false
  import CommsCore.MessagingFixtures
  alias CommsCore.{Accounts, Conversations, Messaging, Whiteboards}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.Messaging.Message
  alias CommsCore.Messaging.PersonalContent.Draft
  alias CommsTestSupport.Fixtures

  test "draft versions preserve clear tombstones, conflict, user privacy and transactional erasure" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    id = account.conversation.id
    assert {:ok, %{body: "", version: 0}} = Messaging.get_draft(id, %{}, subject)

    assert {:ok, %{body: "first draft", version: 1}} =
             Messaging.put_draft(id, %{body: "first draft", expected_version: 0}, subject)

    assert {:error, :stale_draft} =
             Messaging.put_draft(id, %{body: "old device", expected_version: 0}, subject)

    assert {:ok, %{body: "", version: 2}} =
             Messaging.put_draft(id, %{body: "", expected_version: 1}, subject)

    assert {:error, :stale_draft} =
             Messaging.put_draft(id, %{body: "first draft", expected_version: 1}, subject)

    foreign = Fixtures.account_fixture() |> Fixtures.subject()
    assert {:error, _} = Messaging.get_draft(id, %{}, foreign)

    assert {:error, :transaction_required} =
             Messaging.erase_personal_content(account.tenant.id, :user, account.user.id)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Messaging.erase_personal_content(account.tenant.id, :user, account.user.id)
             end)

    assert Repo.aggregate(Draft, :count) == 0
  end

  test "draft expiry hides and physically scrubs content while advancing the version" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, _} =
             Messaging.put_draft(
               account.conversation.id,
               %{body: "expires", expected_version: 0},
               subject
             )

    from(d in Draft)
    |> Repo.update_all(
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1) |> DateTime.truncate(:microsecond)]
    )

    assert {:ok, %{body: "", version: 1}} =
             Messaging.get_draft(account.conversation.id, %{}, subject)

    assert {:error, :forbidden} = Messaging.prune_expired_drafts(__MODULE__)
    worker = CommsCore.RuntimePorts.job_worker!(:personal_content_cleanup)
    assert {:ok, %{drafts_scrubbed: 1}} = Messaging.prune_expired_drafts(worker)

    assert {:ok, %{body: "", version: 2}} =
             Messaging.get_draft(account.conversation.id, %{}, subject)

    assert Repo.one!(Draft).body == ""
  end

  test "saved messages remain user private and follow source removal" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    {:ok, message} =
      Messaging.accept_message(message_attrs(account, "saved-message-source", []), subject)

    assert {:ok, %{saved: true}} = Messaging.save_message(message.id, subject)
    assert {:ok, %{messages: [saved]}} = Messaging.saved_items(subject, %{})
    assert saved.id == message.id
    foreign = Fixtures.account_fixture() |> Fixtures.subject()
    assert {:ok, %{messages: []}} = Messaging.saved_items(foreign, %{})
    assert {:error, :not_found} = Messaging.save_message(message.id, foreign)

    Repo.update_all(from(m in Message, where: m.id == ^message.id),
      set: [status: :deleted, body: nil]
    )

    assert {:ok, %{messages: []}} = Messaging.saved_items(subject, %{})
  end

  test "attachment-only thread replies require a real clean claim and rollback invalid claims" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    {:ok, root} =
      Messaging.accept_message(message_attrs(account, "attachment-thread-root", []), subject)

    attachment = ready_attachment(subject, "a")

    attrs =
      message_attrs(account, "attachment-only-reply", [attachment.id])
      |> Map.merge(%{body: "", reply_to_message_id: root.id})

    assert {:ok, reply} = Messaging.accept_message(attrs, subject)
    assert reply.body in [nil, ""]
    assert reply.thread_root_message_id == root.id
    assert Repo.get!(Message, reply.id).attachment_count == 1

    assert {:error, :invalid_attachments} =
             Messaging.accept_message(
               %{attrs | client_message_id: "duplicate-attachment-reply"},
               subject
             )

    assert {:error, :message_body_required} =
             Messaging.accept_message(
               %{attrs | client_message_id: "empty-unattached-reply", attachment_ids: []},
               subject
             )
  end

  test "checkpoints restore atomically, title CAS works and erasure prevents resurrection" do
    previous = Application.get_env(:comms_core, :whiteboard_snapshot_interval)
    Application.put_env(:comms_core, :whiteboard_snapshot_interval, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :whiteboard_snapshot_interval, previous),
        else: Application.delete_env(:comms_core, :whiteboard_snapshot_interval)
    end)

    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    id = account.conversation.id

    assert {:ok, _, :created} =
             append(id, subject, "first", [text("element-first", "private first")])

    assert {:ok, checkpoint} =
             Whiteboards.checkpoint(id, %{label: "First", expected_sequence: 1}, subject)

    assert {:ok, %{library_version: 2}} =
             Whiteboards.rename(id, %{title: "Planning board", expected_version: 1}, subject)

    assert {:error, :stale_board_version} =
             Whiteboards.rename(id, %{title: "Stale name", expected_version: 1}, subject)

    assert {:ok, _, :created} = append(id, subject, "second", [text("element-second", "second")])

    assert {:error, :stale_board_version} =
             Whiteboards.restore(id, checkpoint.id, %{expected_sequence: 1}, subject)

    assert {:ok, %{sequence: 4}} =
             Whiteboards.restore(id, checkpoint.id, %{expected_sequence: 2}, subject)

    assert {:ok, %{elements: [restored]}} = Whiteboards.export(id, subject)
    assert restored["text"] == "private first"
    assert {:ok, %{boards: [board]}} = Whiteboards.gallery(subject, %{q: "Planning"})
    assert board.title == "Planning board"

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               Whiteboards.erase_for_governance(
                 account.tenant.id,
                 :user,
                 account.user.id,
                 DateTime.utc_now()
               )
             end)

    assert {:ok, []} = Whiteboards.versions(id, subject)
    assert {:ok, %{elements: []}} = Whiteboards.export(id, subject)
  end

  test "only approved message-bound raster assets can be appended or exported" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    id = account.conversation.id

    assert {:ok, _, :created} =
             Whiteboards.append_operation(
               id,
               %{client_operation_id: "create-empty-board", kind: "board.clear", payload: %{}},
               subject
             )

    a = ready_attachment(subject, "b")

    # Fixture scanner approved immutable bytes; MIME mutation is test-only to exercise image binding.
    Repo.update_all(from(a in Attachment, where: a.id == ^a.id), set: [content_type: "image/png"])
    assert {:error, :asset_unavailable} = Whiteboards.add_asset(id, a.id, subject)

    {:ok, source} =
      Messaging.accept_message(message_attrs(account, "board-image-source", [a.id]), subject)

    assert {:ok, asset} = Whiteboards.add_asset(id, a.id, subject)

    image = %{
      "id" => "image-element-one",
      "type" => "image",
      "version" => 1,
      "versionNonce" => 1,
      "fileId" => asset.id,
      "link" => nil,
      "customData" => nil
    }

    assert {:ok, _, :created} = append(id, subject, "approved-image", [image], 1)
    assert {:ok, _} = Whiteboards.asset_download(id, asset.id, subject)

    assert {:error, :invalid_whiteboard_operation} =
             append(
               id,
               subject,
               "inline-image",
               [Map.put(image, "dataURL", "data:image/svg+xml,evil")],
               1
             )

    assert {:error, :asset_unavailable} =
             append(
               id,
               subject,
               "unbound-image",
               [Map.put(image, "fileId", Ecto.UUID.generate())],
               1
             )

    for status <- [:moderated, :deleted] do
      Repo.update_all(from(m in Message, where: m.id == ^source.id), set: [status: status])
      assert {:error, :asset_unavailable} = Whiteboards.asset_download(id, asset.id, subject)
      assert {:error, :asset_unavailable} = Whiteboards.export(id, subject)
    end
  end

  test "another manager's nested restore retains original erasure lineage and preserves unrelated updates" do
    previous = Application.get_env(:comms_core, :whiteboard_snapshot_interval)
    Application.put_env(:comms_core, :whiteboard_snapshot_interval, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :whiteboard_snapshot_interval, previous),
        else: Application.delete_env(:comms_core, :whiteboard_snapshot_interval)
    end)

    account = Fixtures.account_fixture()
    author = Fixtures.subject(account)
    manager = signed_in_member(account)
    id = account.conversation.id
    assert {:ok, _} = Conversations.add_member(id, manager.user.id, :moderator, author)

    assert {:ok, _, :created} =
             append(id, author, "original-lineage", [text("author-text", "erase needle")])

    assert {:ok, original} =
             Whiteboards.checkpoint(
               id,
               %{label: "Author checkpoint", expected_sequence: 1},
               author
             )

    assert {:ok, %{sequence: 3}} =
             Whiteboards.restore(id, original.id, %{expected_sequence: 1}, manager.subject)

    assert {:ok, nested} =
             Whiteboards.checkpoint(
               id,
               %{label: "Manager checkpoint", expected_sequence: 3},
               manager.subject
             )

    assert {:ok, _, :created} =
             append(
               id,
               manager.subject,
               "between-restores",
               [text("discarded-between", "between")],
               2
             )

    assert {:ok, %{sequence: 6}} =
             Whiteboards.restore(id, nested.id, %{expected_sequence: 4}, manager.subject)

    # Client-supplied lineage is ignored; only the internal restore path assigns it.
    assert {:ok, independent, :created} =
             Whiteboards.append_operation(
               id,
               %{
                 client_operation_id: "independent-manager-update",
                 kind: "scene.update",
                 base_sequence: 5,
                 source_actor_user_ids: [account.user.id],
                 payload: %{"elements" => [text("manager-text", "manager keeps this")]}
               },
               manager.subject
             )

    assert Repo.get!(CommsCore.Whiteboards.Operation, independent.id).source_actor_user_ids == []
    assert {:ok, %{elements: before}} = Whiteboards.export(id, manager.subject)
    assert Enum.any?(before, &(&1["text"] == "erase needle"))

    assert {:ok, {:ok, %{whiteboard_operations_neutralized: 3}}} =
             Repo.transaction(fn ->
               Whiteboards.erase_for_governance(
                 account.tenant.id,
                 :user,
                 account.user.id,
                 DateTime.utc_now()
               )
             end)

    assert {:ok, []} = Whiteboards.versions(id, manager.subject)

    assert {:error, :not_found} =
             Whiteboards.restore(id, nested.id, %{expected_sequence: 7}, manager.subject)

    assert {:ok, %{elements: [retained]}} = Whiteboards.export(id, manager.subject)
    assert retained["text"] == "manager keeps this"
    assert {:ok, []} = Whiteboards.search("erase needle", manager.subject)
  end

  test "a checkpoint with large valid elements restores within operation byte limits" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    id = account.conversation.id
    elements = for n <- 1..9, do: text("large-element-#{n}", String.duplicate("x", 60_000))
    assert {:ok, _, :created} = append(id, subject, "large-first", Enum.take(elements, 8))
    assert {:ok, _, :created} = append(id, subject, "large-last", Enum.drop(elements, 8))

    assert {:ok, version} =
             Whiteboards.checkpoint(id, %{label: "Large scene", expected_sequence: 2}, subject)

    assert {:ok, %{sequence: 5}} =
             Whiteboards.restore(id, version.id, %{expected_sequence: 2}, subject)

    assert {:ok, %{elements: restored}} = Whiteboards.export(id, subject)
    assert restored == elements
  end

  test "cleared board text cannot reappear in search" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    id = account.conversation.id

    assert {:ok, _, :created} =
             append(id, subject, "search-secret", [text("element-secret", "needle hidden")])

    assert {:ok, [_]} = Whiteboards.search("needle", subject)

    assert {:ok, _, :created} =
             Whiteboards.append_operation(
               id,
               %{client_operation_id: "clear-search-board", kind: "board.clear", payload: %{}},
               subject
             )

    assert {:ok, []} = Whiteboards.search("needle", subject)
  end

  defp append(id, subject, key, elements, base \\ 0),
    do:
      Whiteboards.append_operation(
        id,
        %{
          client_operation_id: "rich-content-" <> key,
          kind: "scene.update",
          base_sequence: base,
          payload: %{"elements" => elements}
        },
        subject
      )

  defp text(id, content),
    do: %{
      "id" => id,
      "type" => "text",
      "version" => 1,
      "versionNonce" => 1,
      "text" => content,
      "link" => nil,
      "customData" => nil
    }

  defp signed_in_member(account) do
    member = Fixtures.user_fixture(account)
    [local, _domain] = String.split(member.user.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")

    assert {:ok, signed_in} =
             Accounts.authenticate_view(
               account.tenant.slug,
               member.user.email,
               "correct-horse-battery-#{suffix}",
               %{name: "Board manager browser", platform: "test"}
             )

    assert {:ok, access_context} = Accounts.access_context(signed_in.session_id)
    %{user: signed_in.user, subject: access_context.subject}
  end
end
