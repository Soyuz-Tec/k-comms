defmodule CommsCore.Conversations.PublicChannelsTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Audit, Conversations, Repo}
  alias CommsCore.Conversations.Membership
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "tenant public-channel policy is enforced at the command boundary" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, _settings} =
             Administration.update_tenant_settings(
               %{version: 1, allow_public_channels: false},
               subject
             )

    assert {:error, :public_channels_disabled} =
             Conversations.create(
               %{kind: "channel", title: "Forbidden public channel", visibility: "tenant"},
               subject
             )
  end

  test "public-channel discovery is tenant scoped, searchable, paginated, and exposes joined state" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {_member, member_subject} = member_subject_fixture(account)

    assert {:ok, first_channel} =
             Conversations.create(
               %{kind: "channel", title: "Launch Alpha", visibility: "tenant"},
               owner_subject
             )

    assert {:ok, second_channel} =
             Conversations.create(
               %{kind: "channel", title: "Launch Beta", visibility: "tenant"},
               owner_subject
             )

    assert {:ok, _private_channel} =
             Conversations.create(
               %{kind: "channel", title: "Launch Hidden", visibility: "private"},
               owner_subject
             )

    assert {:ok, _tenant_group} =
             Conversations.create(
               %{kind: "group", title: "Launch Group", visibility: "tenant"},
               owner_subject
             )

    assert {:ok, archived_channel} =
             Conversations.create(
               %{kind: "channel", title: "Launch Archived", visibility: "tenant"},
               owner_subject
             )

    assert {:ok, _archived} =
             Conversations.archive(
               archived_channel.id,
               %{version: archived_channel.lock_version},
               owner_subject
             )

    other_account = Fixtures.account_fixture()

    assert {:ok, _other_tenant_channel} =
             Conversations.create(
               %{kind: "channel", title: "Launch Other Tenant", visibility: "tenant"},
               Fixtures.subject(other_account)
             )

    assert {:ok, page_one} =
             Conversations.discover_public_channels(
               %{q: "launch", limit: 1},
               member_subject
             )

    assert page_one.has_more
    assert is_binary(page_one.next_cursor)
    assert [%{joined: false, member_count: 1, membership: nil}] = page_one.channels

    assert {:ok, page_two} =
             Conversations.discover_public_channels(
               %{q: "launch", limit: 1, cursor: page_one.next_cursor},
               member_subject
             )

    refute page_two.has_more
    assert is_nil(page_two.next_cursor)
    assert [%{joined: false, member_count: 1, membership: nil}] = page_two.channels

    discovered_ids =
      (page_one.channels ++ page_two.channels)
      |> Enum.map(& &1.conversation.id)
      |> MapSet.new()

    assert discovered_ids == MapSet.new([first_channel.id, second_channel.id])

    assert {:ok, owner_page} =
             Conversations.discover_public_channels(%{q: "Launch Alpha"}, owner_subject)

    assert [owner_result] = owner_page.channels
    assert owner_result.joined
    assert owner_result.membership.role == :owner
    assert owner_result.member_count == 1

    assert {:error, :invalid_cursor} =
             Conversations.discover_public_channels(%{cursor: "not-opaque"}, member_subject)
  end

  @tag :concurrency
  test "self-join is concurrency safe and self-leave is versioned and idempotent" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {member, member_subject} = member_subject_fixture(account)

    assert {:ok, channel} =
             Conversations.create(
               %{kind: "channel", title: "Community", visibility: "tenant"},
               owner_subject
             )

    results =
      1..4
      |> Task.async_stream(
        fn _ -> Conversations.join_public_channel(channel.id, member_subject) end,
        max_concurrency: 4,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.count(results, fn {:ok, result} -> not result.replayed end) == 1
    assert Enum.count(results, fn {:ok, result} -> result.replayed end) == 3

    memberships =
      Repo.all(
        from(m in Membership,
          where:
            m.tenant_id == ^account.tenant.id and m.conversation_id == ^channel.id and
              m.user_id == ^member.id and is_nil(m.left_at)
        )
      )

    assert [%Membership{role: :member} = membership] = memberships

    membership_events =
      Repo.all(
        from(event in OutboxEvent,
          where:
            event.tenant_id == ^account.tenant.id and event.aggregate_id == ^channel.id and
              event.event_type == "membership.changed.v1"
        )
      )

    assert [joined_event] = membership_events
    assert joined_event.payload["action"] == "added"
    assert joined_event.payload["source"] == "self_service"
    refute Map.has_key?(joined_event.payload, "body")
    refute Map.has_key?(joined_event.payload, "title")

    membership_audits =
      Audit.list(%{
        tenant_id: account.tenant.id,
        resource_id: channel.id,
        action: "membership.changed"
      })

    assert [joined_audit] = membership_audits
    refute Map.has_key?(joined_audit.metadata, "body")
    refute Map.has_key?(joined_audit.metadata, "title")

    assert {:error, :stale_version} =
             Conversations.leave_public_channel(
               channel.id,
               %{version: membership.lock_version + 1},
               member_subject
             )

    assert {:ok, left} =
             Conversations.leave_public_channel(
               channel.id,
               %{version: membership.lock_version},
               member_subject
             )

    refute left.replayed
    assert left.membership.left_at
    assert left.membership.lock_version == membership.lock_version + 1

    assert {:ok, repeated_leave} =
             Conversations.leave_public_channel(
               channel.id,
               %{version: membership.lock_version},
               member_subject
             )

    assert repeated_leave.replayed
    assert repeated_leave.membership.id == membership.id

    assert Repo.aggregate(
             from(event in OutboxEvent,
               where:
                 event.tenant_id == ^account.tenant.id and
                   event.aggregate_id == ^channel.id and
                   event.event_type == "membership.changed.v1"
             ),
             :count
           ) == 2

    assert {:ok, owner_members} = Conversations.list_members(channel.id, owner_subject)
    owner_membership = List.first(owner_members).membership

    assert {:error, :cannot_remove_owner} =
             Conversations.leave_public_channel(
               channel.id,
               %{version: owner_membership.lock_version},
               owner_subject
             )
  end

  test "self-membership rejects non-public, archived, cross-tenant, and policy-disabled channels" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)
    {member, member_subject} = member_subject_fixture(account)

    assert {:ok, direct} =
             Conversations.create(
               %{kind: "direct", member_ids: [member.id]},
               owner_subject
             )

    assert {:ok, group} =
             Conversations.create(
               %{kind: "group", title: "Tenant group", visibility: "tenant"},
               owner_subject
             )

    assert {:ok, private_channel} =
             Conversations.create(
               %{kind: "channel", title: "Private", visibility: "private"},
               owner_subject
             )

    assert {:ok, archived_channel} =
             Conversations.create(
               %{kind: "channel", title: "Archived", visibility: "tenant"},
               owner_subject
             )

    assert {:ok, _archived} =
             Conversations.archive(
               archived_channel.id,
               %{version: archived_channel.lock_version},
               owner_subject
             )

    assert {:ok, public_channel} =
             Conversations.create(
               %{kind: "channel", title: "Public", visibility: "tenant"},
               owner_subject
             )

    for conversation <- [direct, group, private_channel, archived_channel] do
      assert {:error, :forbidden} =
               Conversations.join_public_channel(conversation.id, member_subject)
    end

    direct_membership =
      Repo.get_by!(Membership,
        tenant_id: account.tenant.id,
        conversation_id: direct.id,
        user_id: member.id
      )

    assert {:error, :forbidden} =
             Conversations.leave_public_channel(
               direct.id,
               %{version: direct_membership.lock_version},
               member_subject
             )

    other_account = Fixtures.account_fixture()
    other_subject = Fixtures.subject(other_account)

    assert {:error, :forbidden} =
             Conversations.join_public_channel(public_channel.id, other_subject)

    assert {:ok, _settings} =
             Administration.update_tenant_settings(
               %{version: 1, allow_public_channels: false},
               owner_subject
             )

    assert {:error, :public_channels_disabled} =
             Conversations.discover_public_channels(%{}, member_subject)

    assert {:error, :public_channels_disabled} =
             Conversations.join_public_channel(public_channel.id, member_subject)
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
