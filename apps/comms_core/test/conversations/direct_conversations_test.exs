defmodule CommsCore.Conversations.DirectConversationsTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Conversations, Repo}
  alias CommsCore.Conversations.{Conversation, ConversationView, Membership}
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "direct conversation membership is immutable" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    third_user = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, %ConversationView{} = direct} =
             Conversations.create_view(
               %{
                 kind: "direct",
                 title: "Client-supplied label",
                 visibility: "tenant",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert direct.visibility == :private
    assert direct.title == nil
    assert direct.counterpart_user_id == member.user.id
    assert direct.counterpart_display_name == member.user.display_name
    assert Repo.get!(Conversation, direct.id).title == nil

    assert {:error, :direct_membership_immutable} =
             Conversations.add_member(direct.id, third_user.user.id, "member", subject)

    assert {:ok, members} = Conversations.list_members(direct.id, subject)
    assert length(members) == 2

    assert {:ok, updated} =
             Conversations.update_view(
               direct.id,
               %{title: "Spoofed title", visibility: "tenant", version: direct.version},
               subject
             )

    assert updated.title == nil
    assert updated.visibility == :private
    assert updated.counterpart_user_id == member.user.id
    assert updated.counterpart_display_name == member.user.display_name
    assert Repo.get!(Conversation, direct.id).title == nil

    assert {:ok, archived} =
             Conversations.archive_view(direct.id, %{version: updated.version}, subject)

    assert archived.counterpart_user_id == member.user.id
    assert archived.counterpart_display_name == member.user.display_name
  end

  test "direct start is idempotent for both members and emits one creation event" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {member, member_subject} = member_subject_fixture(account)

    assert {:ok, %{conversation: created, created: true}} =
             Conversations.get_or_create_direct_view(member.id, owner_subject)

    assert created.kind == :direct
    assert created.visibility == :private
    assert created.title == nil
    assert created.counterpart_user_id == member.id
    assert created.counterpart_display_name == member.display_name

    assert {:ok, %{conversation: replayed, created: false}} =
             Conversations.get_or_create_direct_view(member.id, owner_subject)

    assert {:ok, %{conversation: member_replayed, created: false}} =
             Conversations.get_or_create_direct_view(account.user.id, member_subject)

    assert replayed.id == created.id
    assert replayed.counterpart_user_id == member.id
    assert replayed.counterpart_display_name == member.display_name
    assert member_replayed.id == created.id
    assert member_replayed.counterpart_user_id == account.user.id
    assert member_replayed.counterpart_display_name == account.user.display_name

    assert %ConversationView{
             counterpart_user_id: counterpart_user_id,
             counterpart_display_name: counterpart_name
           } =
             Enum.find(
               Conversations.list_for_user_views(owner_subject),
               &(&1.id == created.id)
             )

    assert counterpart_user_id == member.id
    assert counterpart_name == member.display_name

    assert {:ok, %ConversationView{} = owner_view} =
             Conversations.get_for_user_view(created.id, owner_subject)

    assert owner_view.counterpart_user_id == member.id
    assert owner_view.counterpart_display_name == member.display_name

    assert %ConversationView{
             counterpart_user_id: owner_user_id,
             counterpart_display_name: owner_name
           } =
             Enum.find(
               Conversations.list_for_user_views(member_subject),
               &(&1.id == created.id)
             )

    assert owner_user_id == account.user.id
    assert owner_name == account.user.display_name

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where:
                 event.tenant_id == ^account.tenant.id and event.aggregate_id == ^created.id and
                   event.event_type == "conversation.created.v1"
             ),
             :count
           ) == 1
  end

  @tag :concurrency
  test "concurrent direct starts return one conversation and one membership pair" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    member = Fixtures.user_fixture(account).user

    results =
      1..6
      |> Task.async_stream(
        fn _ -> Conversations.get_or_create_direct_view(member.id, subject) end,
        max_concurrency: 6,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{conversation: _, created: _}}, &1))
    assert Enum.count(results, &match?({:ok, %{created: true}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{created: false}}, &1)) == 5

    conversation_ids =
      Enum.map(results, fn {:ok, %{conversation: conversation}} -> conversation.id end)

    assert [conversation_id] = Enum.uniq(conversation_ids)

    assert Repo.aggregate(
             from(membership in Membership,
               where:
                 membership.tenant_id == ^account.tenant.id and
                   membership.conversation_id == ^conversation_id and
                   is_nil(membership.left_at)
             ),
             :count
           ) == 2
  end

  test "direct start preserves identity privacy, tenant isolation, and quotas" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    member = Fixtures.user_fixture(account).user
    suspended = Fixtures.user_fixture(account, %{status: :suspended}).user
    service = Fixtures.user_fixture(account, %{account_type: :service}).user
    foreign = Fixtures.account_fixture().user

    for unavailable_id <- [account.user.id, suspended.id, service.id, foreign.id] do
      assert {:error, :not_found} =
               Conversations.get_or_create_direct_view(unavailable_id, subject)
    end

    assert {:ok, settings_result} =
             Administration.update_tenant_settings(
               %{version: 1, max_active_conversations: 2},
               subject
             )

    assert {:ok, %{conversation: direct, created: true}} =
             Conversations.get_or_create_direct_view(member.id, subject)

    assert {:ok, _settings_result} =
             Administration.update_tenant_settings(
               %{
                 version: settings_result.settings.lock_version,
                 max_active_conversations: 1
               },
               subject
             )

    assert {:ok, %{conversation: resumed, created: false}} =
             Conversations.get_or_create_direct_view(member.id, subject)

    assert resumed.id == direct.id

    another_member = Fixtures.user_fixture(account).user

    assert {:error, :active_conversation_quota_exceeded} =
             Conversations.get_or_create_direct_view(another_member.id, subject)

    assert {:error, :forbidden} =
             Conversations.get_or_create_direct_view(
               member.id,
               Map.put(subject, :session_id, Ecto.UUID.generate())
             )
  end

  defp member_subject_fixture(account) do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-member-password-#{suffix}"
    email = "channel-member-#{suffix}@example.test"

    assert {:ok, member} =
             Accounts.create_user(
               %{
                 display_name: "Channel Member #{suffix}",
                 email: email,
                 password: password,
                 role: "member"
               },
               Fixtures.step_up(account)
             )

    assert {:ok, login} =
             Accounts.authenticate_view(account.tenant.slug, email, password, %{
               name: "Channel browser",
               platform: "test"
             })

    {:ok, access_context} = Accounts.access_context(login.session_id, "channel-test")
    {member, access_context.subject}
  end
end
