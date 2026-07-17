defmodule CommsCore.MessagingMentionsThreadsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Messaging.{Message, MessageMention, MessageView}
  alias CommsCore.{Conversations, Governance, Messaging, Repo}
  alias CommsTestSupport.Fixtures

  test "mentions are explicit, tenant-safe, membership-validated, and idempotent" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    mentioned = Fixtures.user_fixture(account).user

    assert {:ok, _membership} =
             Conversations.add_member(account.conversation.id, mentioned.id, "member", subject)

    attrs =
      message_attrs(account, "mention-message-0001", %{
        mentioned_user_ids: [mentioned.id, mentioned.id]
      })

    assert {:ok, created, :created} = Messaging.accept_message_with_status(attrs, subject)
    assert %MessageView{} = created
    refute match?(%Message{}, created)
    assert created.mentioned_user_ids == [mentioned.id]
    assert created.thread_root_message_id == nil

    assert {:ok, replayed, :duplicate} = Messaging.accept_message_with_status(attrs, subject)
    assert %MessageView{} = replayed
    refute match?(%Message{}, replayed)
    assert replayed.id == created.id
    assert replayed.mentioned_user_ids == [mentioned.id]

    assert Repo.aggregate(
             from(mention in MessageMention, where: mention.message_id == ^created.id),
             :count
           ) == 1

    mention_event =
      Repo.get_by!(OutboxEvent,
        aggregate_id: created.id,
        event_type: "mention.created.v1"
      )

    assert mention_event.payload["mentioned_user_ids"] == [mentioned.id]
    refute Map.has_key?(mention_event.payload, "body")

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where:
                 event.aggregate_id == ^created.id and
                   event.event_type == "mention.created.v1"
             ),
             :count
           ) == 1

    nonmember = Fixtures.user_fixture(account).user

    assert {:error, :invalid_mentions} =
             account
             |> message_attrs("mention-nonmember-0001", %{mentioned_user_ids: [nonmember.id]})
             |> Messaging.accept_message(subject)

    other = Fixtures.account_fixture()

    assert {:error, :invalid_mentions} =
             account
             |> message_attrs("mention-cross-tenant", %{
               mentioned_user_ids: [other.user.id]
             })
             |> Messaging.accept_message(subject)

    assert {:error, :too_many_mentions} =
             account
             |> message_attrs("mention-too-many-0001", %{
               mentioned_user_ids: List.duplicate(mentioned.id, 51)
             })
             |> Messaging.accept_message(subject)

    assert {:error, :invalid_mention_id} =
             account
             |> message_attrs("mention-invalid-id-01", %{mentioned_user_ids: ["not-a-uuid"]})
             |> Messaging.accept_message(subject)
  end

  test "nested replies retain their immediate parent and one canonical thread root" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, root} =
             account
             |> message_attrs("thread-root-message-01")
             |> Messaging.accept_message(subject)

    assert {:ok, first_reply} =
             account
             |> message_attrs("thread-first-reply-01", %{reply_to_message_id: root.id})
             |> Messaging.accept_message(subject)

    assert {:ok, nested_reply} =
             account
             |> message_attrs("thread-nested-reply1", %{reply_to_message_id: first_reply.id})
             |> Messaging.accept_message(subject)

    assert first_reply.reply_to_message_id == root.id
    assert first_reply.thread_root_message_id == root.id
    assert nested_reply.reply_to_message_id == first_reply.id
    assert nested_reply.thread_root_message_id == root.id

    assert {:ok, first_page} =
             Messaging.get_thread(account.conversation.id, nested_reply.id, subject, limit: 1)

    assert %MessageView{} = first_page.root
    assert Enum.all?(first_page.replies, &match?(%MessageView{}, &1))
    assert first_page.root.id == root.id
    assert first_page.reply_count == 2
    assert Enum.map(first_page.replies, & &1.id) == [nested_reply.id]
    assert first_page.has_more
    assert first_page.next_before_sequence == nested_reply.conversation_sequence

    assert {:ok, older_page} =
             Messaging.get_thread(account.conversation.id, root.id, subject,
               limit: 1,
               before_sequence: first_page.next_before_sequence
             )

    assert Enum.map(older_page.replies, & &1.id) == [first_reply.id]
    refute older_page.has_more

    assert {:ok, deleted_root} = Governance.delete_message(root.id, subject)
    assert deleted_root.status == :deleted

    assert {:ok, deleted_thread} =
             Messaging.get_thread(account.conversation.id, first_reply.id, subject)

    assert deleted_thread.root.status == :deleted
    assert Enum.map(deleted_thread.replies, & &1.id) == [first_reply.id, nested_reply.id]
  end

  test "thread reads enforce membership and database constraints reject cross-tenant mentions" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, root} =
             account
             |> message_attrs("thread-auth-root-0001")
             |> Messaging.accept_message(subject)

    nonmember_subject = nonmember_subject(account, subject)

    assert {:error, :forbidden} =
             Messaging.get_thread(
               account.conversation.id,
               root.id,
               nonmember_subject
             )

    other = Fixtures.account_fixture()

    assert {:error, changeset} =
             %MessageMention{}
             |> MessageMention.changeset(%{
               tenant_id: other.tenant.id,
               message_id: root.id,
               user_id: other.user.id
             })
             |> Repo.insert()

    assert {"does not exist", _metadata} = changeset.errors[:message_id]
  end

  test "physical root deletion clears only thread references and keeps tenant ownership intact" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    {:ok, root} =
      account
      |> message_attrs("physical-root-delete1")
      |> Messaging.accept_message(subject)

    {:ok, reply} =
      account
      |> message_attrs("physical-root-reply01", %{reply_to_message_id: root.id})
      |> Messaging.accept_message(subject)

    root_schema = Repo.get!(Message, root.id)
    assert {:ok, _deleted} = Repo.delete(root_schema)

    persisted = Repo.get!(Message, reply.id)
    assert persisted.reply_to_message_id == nil
    assert persisted.thread_root_message_id == nil
    assert persisted.tenant_id == account.tenant.id
    assert persisted.conversation_id == account.conversation.id
  end

  defp nonmember_subject(account, owner_subject) do
    password = "correct-horse-thread-nonmember"
    owner_subject = Fixtures.step_up(account, owner_subject)

    {:ok, user} =
      Accounts.create_user(
        %{
          display_name: "Thread nonmember",
          email: "thread-nonmember@example.test",
          password: password,
          role: "member"
        },
        owner_subject
      )

    {:ok, login} =
      Accounts.authenticate(account.tenant.slug, user.email, password, %{
        name: "Thread nonmember browser",
        platform: "test"
      })

    Accounts.subject_for_session(login.session)
  end

  defp message_attrs(account, client_message_id, overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: account.tenant.id,
        conversation_id: account.conversation.id,
        sender_user_id: account.user.id,
        sender_device_id: account.device.id,
        client_message_id: client_message_id,
        body: "message body",
        attachment_ids: [],
        mentioned_user_ids: []
      },
      overrides
    )
  end
end
