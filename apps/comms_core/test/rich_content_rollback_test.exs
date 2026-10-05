defmodule CommsCore.RichContentRollbackTest do
  use CommsCore.DataCase, async: false
  import CommsCore.MessagingFixtures
  alias CommsCore.{Messaging, Whiteboards}
  alias CommsCore.Attachments.Attachment
  alias CommsTestSupport.Fixtures

  test "private saved and draft scopes block rollback until actual owner erasure across tenants" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    {:ok, message} =
      Messaging.accept_message(message_attrs(account, "rollback-plain-message", []), subject)

    assert Messaging.rollback_rich_content_hazard_count() == 0
    assert {:ok, _} = Messaging.save_message(message.id, subject)
    assert Messaging.rollback_rich_content_hazard_count() == 1

    assert {:ok, _} =
             Messaging.put_draft(
               account.conversation.id,
               %{body: "private draft", expected_version: 0},
               subject
             )

    assert Messaging.rollback_rich_content_hazard_count() == 2

    assert {:ok, _} =
             Messaging.put_draft(
               account.conversation.id,
               %{body: "", expected_version: 1},
               subject
             )

    assert Messaging.rollback_rich_content_hazard_count() == 2

    other = Fixtures.account_fixture()

    assert {:ok, _} =
             Messaging.put_draft(
               other.conversation.id,
               %{body: "other tenant", expected_version: 0},
               Fixtures.subject(other)
             )

    assert Messaging.rollback_rich_content_hazard_count() == 3

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Messaging.erase_personal_content(account.tenant.id, :user, account.user.id)
             end)

    assert Messaging.rollback_rich_content_hazard_count() == 1

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Messaging.erase_personal_content(other.tenant.id, :user, other.user.id)
             end)

    assert Messaging.rollback_rich_content_hazard_count() == 0
  end

  test "ordinary formatted message revisions and existing attachment erasure do not create private-scope hazards" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    attrs =
      message_attrs(account, "rollback-format-source", []) |> Map.put(:body, "**formatted text**")

    assert {:ok, message} = Messaging.accept_message(attrs, subject)
    assert {:ok, _} = Messaging.edit_message(message.id, "_edited format_", subject)
    attachment = ready_attachment(subject, "c")

    assert {:ok, _} =
             Messaging.accept_message(
               message_attrs(account, "rollback-attachment-only", [attachment.id])
               |> Map.put(:body, ""),
               subject
             )

    assert Messaging.rollback_rich_content_hazard_count() == 0
  end

  test "rich board obligations include cache lineage and end only after owned erasure" do
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

    element = %{
      "id" => "rollback-element",
      "type" => "text",
      "version" => 1,
      "versionNonce" => 1,
      "text" => "private board text"
    }

    assert {:ok, _, :created} =
             Whiteboards.append_operation(
               id,
               %{
                 client_operation_id: "rollback-ordinary-scene",
                 kind: "scene.update",
                 payload: %{"elements" => [element]}
               },
               subject
             )

    assert Whiteboards.rollback_rich_content_hazard_count() == 0

    assert {:ok, _} =
             Whiteboards.rename(id, %{title: "Private planning", expected_version: 1}, subject)

    assert Whiteboards.rollback_rich_content_hazard_count() == 1

    assert {:ok, checkpoint} =
             Whiteboards.checkpoint(
               id,
               %{label: "Private checkpoint", expected_sequence: 1},
               subject
             )

    assert Whiteboards.rollback_rich_content_hazard_count() == 2

    assert {:ok, %{sequence: 3}} =
             Whiteboards.restore(id, checkpoint.id, %{expected_sequence: 1}, subject)

    assert Whiteboards.rollback_rich_content_hazard_count() == 4

    attachment = ready_attachment(subject, "d")

    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
      set: [content_type: "image/png"]
    )

    assert {:ok, _} =
             Messaging.accept_message(
               message_attrs(account, "rollback-image-source", [attachment.id]),
               subject
             )

    assert {:ok, _} = Whiteboards.add_asset(id, attachment.id, subject)
    assert Whiteboards.rollback_rich_content_hazard_count() == 5

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               Whiteboards.erase_for_governance(
                 account.tenant.id,
                 :user,
                 account.user.id,
                 DateTime.utc_now()
               )
             end)

    assert Whiteboards.rollback_rich_content_hazard_count() == 0
  end

  test "missing draft inventory fails closed even when the database otherwise has zero hazards" do
    Repo.query!("DROP TABLE public.message_drafts")

    assert_raise RuntimeError, "ConversationContent rich rollback inventory unavailable", fn ->
      Messaging.rollback_rich_content_hazard_count()
    end
  end

  test "missing saved reference columns fail closed" do
    Repo.query!("ALTER TABLE public.message_saved_items DROP COLUMN message_id")

    assert_raise RuntimeError, "ConversationContent rich rollback inventory unavailable", fn ->
      Messaging.rollback_rich_content_hazard_count()
    end
  end

  test "missing checkpoint inventory fails closed" do
    Repo.query!("DROP TABLE public.whiteboard_versions")

    assert_raise RuntimeError, "Collaboration rich rollback inventory unavailable", fn ->
      Whiteboards.rollback_rich_content_hazard_count()
    end
  end

  test "missing restore lineage columns fail closed" do
    Repo.query!("ALTER TABLE public.whiteboard_operations DROP COLUMN source_actor_user_ids")

    assert_raise RuntimeError, "Collaboration rich rollback inventory unavailable", fn ->
      Whiteboards.rollback_rich_content_hazard_count()
    end
  end

  test "missing derived snapshot inventory fails closed" do
    Repo.query!("DROP TABLE public.whiteboard_snapshots")

    assert_raise RuntimeError, "Collaboration rich rollback inventory unavailable", fn ->
      Whiteboards.rollback_rich_content_hazard_count()
    end
  end
end
