defmodule CommsCore.MessagingMutationsTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :messaging

  alias CommsCore.{Administration, Conversations, Governance, Messaging}
  alias CommsCore.Conversations.Membership
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

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
    assert page_one.sender_labels == []

    assert {:ok, labeled_page} =
             Messaging.search_page("roadmap", subject,
               limit: 1,
               include_sender_labels: true
             )

    assert [
             %CommsCore.Accounts.RetainedSenderLabelView{
               id: sender_id,
               display_name: sender_name
             }
           ] = labeled_page.sender_labels

    assert sender_id == account.user.id
    assert sender_name == account.user.display_name

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
end
