defmodule CommsCore.ConversationsTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Conversations, Repo}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.Membership
  alias CommsCore.Events.OutboxEvent
  alias CommsTestSupport.Fixtures

  test "creates a group and advances the read cursor monotonically" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Product",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, result} = Conversations.get_for_user(conversation.id, subject)
    assert result.membership_role == :owner
    assert {:ok, 0} = Conversations.mark_read(conversation.id, 10, subject)
    assert {:ok, 0} = Conversations.mark_read(conversation.id, 0, subject)

    assert {:ok, members} = Conversations.list_members(conversation.id, subject)
    assert length(members) == 2
  end

  test "active member ids support delivery fanout without leaking departed or unrelated members" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    unrelated_member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Delivery fanout",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, _unrelated_conversation} =
             Conversations.create(
               %{
                 title: "Unrelated delivery fanout",
                 kind: "group",
                 visibility: "private",
                 member_ids: [unrelated_member.user.id]
               },
               subject
             )

    assert MapSet.new(Conversations.active_member_ids(conversation.id)) ==
             MapSet.new([account.user.id, member.user.id])

    assert {:ok, memberships} = Conversations.list_members(conversation.id, subject)
    member_membership = Enum.find(memberships, &(&1.user.id == member.user.id)).membership

    assert {:ok, _removed} =
             Conversations.remove_member(
               conversation.id,
               member.user.id,
               %{version: member_membership.lock_version},
               subject
             )

    assert Conversations.active_member_ids(conversation.id) == [account.user.id]
  end

  test "updates and archives channels with versioned membership ownership" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Operations",
                 kind: "channel",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, updated} =
             Conversations.update(
               conversation.id,
               %{
                 version: conversation.lock_version,
                 title: "Operations team",
                 visibility: "tenant"
               },
               subject
             )

    assert updated.title == "Operations team"
    assert updated.visibility == :tenant

    assert Enum.any?(
             Conversations.list_for_user(subject),
             &(&1.conversation.id == conversation.id)
           )

    assert {:error, :stale_version} =
             Conversations.update(conversation.id, %{version: 1, title: "Stale"}, subject)

    assert {:ok, members} = Conversations.list_members(conversation.id, subject)
    member_membership = Enum.find(members, &(&1.user.id == member.user.id)).membership
    owner_membership = Enum.find(members, &(&1.user.id == account.user.id)).membership

    assert {:ok, promoted} =
             Conversations.change_member_role(
               conversation.id,
               member.user.id,
               %{version: member_membership.lock_version, role: "owner"},
               subject
             )

    assert promoted.role == :owner

    assert {:ok, demoted} =
             Conversations.change_member_role(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version, role: "moderator"},
               subject
             )

    assert demoted.role == :moderator

    assert {:ok, archived} =
             Conversations.archive(conversation.id, %{version: updated.lock_version}, subject)

    assert archived.archived_at

    refute Enum.any?(
             Conversations.list_for_user(subject),
             &(&1.conversation.id == conversation.id)
           )

    assert {:error, :not_found} =
             Conversations.update(
               conversation.id,
               %{version: archived.lock_version, title: "No"},
               subject
             )
  end

  test "direct conversation membership is immutable" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    third_user = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, direct} =
             Conversations.create(
               %{kind: "direct", visibility: "tenant", member_ids: [member.user.id]},
               subject
             )

    assert direct.visibility == :private

    assert {:error, :direct_membership_immutable} =
             Conversations.add_member(direct.id, third_user.user.id, "member", subject)

    assert {:ok, members} = Conversations.list_members(direct.id, subject)
    assert length(members) == 2
  end

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

  test "tenant administrators without membership cannot manage private conversations" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)

    assert {:ok, admin} =
             Accounts.create_user(
               %{
                 display_name: "Private Boundary Admin",
                 email: "private-boundary-admin@example.test",
                 password: "correct-horse-private-boundary",
                 role: "admin"
               },
               owner_subject
             )

    assert {:ok, login} =
             Accounts.authenticate(
               account.tenant.slug,
               admin.email,
               "correct-horse-private-boundary",
               %{name: "Admin browser", platform: "test"}
             )

    admin_subject = Accounts.subject_for_session(login.session)

    assert {:ok, private_group} =
             Conversations.create(
               %{kind: "group", title: "Private group", visibility: "private"},
               owner_subject
             )

    assert {:error, :forbidden} =
             Conversations.update(
               private_group.id,
               %{version: private_group.lock_version, title: "Unauthorized"},
               admin_subject
             )
  end

  test "concurrent owner changes preserve an active conversation owner" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 kind: "channel",
                 title: "Ownership race",
                 visibility: "tenant",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, memberships} = Conversations.list_members(conversation.id, subject)
    owner_membership = Enum.find(memberships, &(&1.user.id == account.user.id)).membership
    member_membership = Enum.find(memberships, &(&1.user.id == member.user.id)).membership

    assert {:ok, second_owner} =
             Conversations.change_member_role(
               conversation.id,
               member.user.id,
               %{version: member_membership.lock_version, role: "owner"},
               subject
             )

    operations = [
      fn ->
        Conversations.change_member_role(
          conversation.id,
          account.user.id,
          %{version: owner_membership.lock_version, role: "member"},
          subject
        )
      end,
      fn ->
        Conversations.remove_member(
          conversation.id,
          member.user.id,
          %{version: second_owner.lock_version},
          subject
        )
      end
    ]

    results =
      operations
      |> Task.async_stream(fn operation -> operation.() end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert {:ok, remaining} = Conversations.list_members(conversation.id, subject)
    assert Enum.count(remaining, &(&1.membership.role == :owner)) == 1
  end

  test "moderators manage ordinary memberships but cannot act on conversation owners" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {moderator, moderator_subject} = role_subject_fixture(account, :moderator)
    ordinary_member = Fixtures.user_fixture(account).user
    unjoined_member = Fixtures.user_fixture(account).user

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 kind: "group",
                 title: "Ownership boundary",
                 visibility: "private",
                 member_ids: [moderator.id, ordinary_member.id]
               },
               owner_subject
             )

    assert {:ok, initial_memberships} =
             Conversations.list_members(conversation.id, owner_subject)

    moderator_membership =
      Enum.find(initial_memberships, &(&1.user.id == moderator.id)).membership

    ordinary_membership =
      Enum.find(initial_memberships, &(&1.user.id == ordinary_member.id)).membership

    owner_membership =
      Enum.find(initial_memberships, &(&1.user.id == account.user.id)).membership

    assert {:ok, promoted_moderator} =
             Conversations.change_member_role(
               conversation.id,
               moderator.id,
               %{version: moderator_membership.lock_version, role: "moderator"},
               owner_subject
             )

    assert {:ok, promoted_ordinary_member} =
             Conversations.change_member_role(
               conversation.id,
               ordinary_member.id,
               %{version: ordinary_membership.lock_version, role: "moderator"},
               moderator_subject
             )

    event_count =
      Repo.aggregate(
        from(event in OutboxEvent,
          where:
            event.tenant_id == ^account.tenant.id and
              event.aggregate_id == ^conversation.id and
              event.event_type == "membership.changed.v1"
        ),
        :count
      )

    assert {:ok, idempotent_membership} =
             Conversations.add_member(
               conversation.id,
               ordinary_member.id,
               :moderator,
               moderator_subject
             )

    assert idempotent_membership.id == promoted_ordinary_member.id
    assert idempotent_membership.lock_version == promoted_ordinary_member.lock_version

    assert event_count ==
             Repo.aggregate(
               from(event in OutboxEvent,
                 where:
                   event.tenant_id == ^account.tenant.id and
                     event.aggregate_id == ^conversation.id and
                     event.event_type == "membership.changed.v1"
               ),
               :count
             )

    assert {:error, :version_required} =
             Conversations.add_member(
               conversation.id,
               ordinary_member.id,
               :member,
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.add_member(
               conversation.id,
               unjoined_member.id,
               :owner,
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.change_member_role(
               conversation.id,
               moderator.id,
               %{version: promoted_moderator.lock_version, role: "owner"},
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.change_member_role(
               conversation.id,
               ordinary_member.id,
               %{version: promoted_ordinary_member.lock_version, role: "owner"},
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.change_member_role(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version, role: "moderator"},
               moderator_subject
             )

    assert {:error, :forbidden} =
             Conversations.remove_member(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version},
               moderator_subject
             )

    assert {:ok, second_owner} =
             Conversations.change_member_role(
               conversation.id,
               ordinary_member.id,
               %{version: promoted_ordinary_member.lock_version, role: "owner"},
               owner_subject
             )

    assert second_owner.role == :owner

    assert {:ok, demoted_original_owner} =
             Conversations.change_member_role(
               conversation.id,
               account.user.id,
               %{version: owner_membership.lock_version, role: "moderator"},
               owner_subject
             )

    assert demoted_original_owner.role == :moderator
  end

  test "tenant administrators retain ownership management for tenant-visible channels" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    {_admin, admin_subject} = role_subject_fixture(account, :admin)
    ordinary_member = Fixtures.user_fixture(account).user

    assert {:ok, channel} =
             Conversations.create(
               %{
                 kind: "channel",
                 title: "Tenant-visible ownership",
                 visibility: "tenant",
                 member_ids: [ordinary_member.id]
               },
               owner_subject
             )

    assert {:ok, memberships} = Conversations.list_members(channel.id, owner_subject)
    membership = Enum.find(memberships, &(&1.user.id == ordinary_member.id)).membership

    assert {:ok, promoted} =
             Conversations.change_member_role(
               channel.id,
               ordinary_member.id,
               %{version: membership.lock_version, role: "owner"},
               admin_subject
             )

    assert promoted.role == :owner
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
      Repo.all(
        from(event in AuditEvent,
          where:
            event.tenant_id == ^account.tenant.id and event.resource_id == ^channel.id and
              event.action == "membership.changed"
        )
      )

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
             Accounts.authenticate(account.tenant.slug, email, password, %{
               name: "Channel browser",
               platform: "test"
             })

    {member, Accounts.subject_for_session(login.session, "channel-test")}
  end

  defp role_subject_fixture(account, role) do
    suffix = System.unique_integer([:positive, :monotonic])
    password = "correct-role-password-#{suffix}"
    email = "#{role}-#{suffix}@example.test"

    assert {:ok, user} =
             Accounts.create_user(
               %{
                 display_name: "#{role} #{suffix}",
                 email: email,
                 password: password,
                 role: Atom.to_string(role)
               },
               Fixtures.step_up(account)
             )

    assert {:ok, login} =
             Accounts.authenticate(account.tenant.slug, email, password, %{
               name: "#{role} browser",
               platform: "test"
             })

    {user, Accounts.subject_for_session(login.session, "role-test")}
  end
end
