defmodule CommsCore.Conversations.DataLifecycleTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  test "governance reference and retention queries are tenant scoped and schema free" do
    account = Fixtures.account_fixture()
    other_account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, active_conversation} =
             Conversations.create(
               %{kind: "group", title: "Active retention scope"},
               subject
             )

    assert {:ok, archived_conversation} =
             Conversations.create(
               %{kind: "group", title: "Archived retention scope"},
               subject
             )

    assert {:ok, _archived} =
             Conversations.archive(
               archived_conversation.id,
               %{version: archived_conversation.lock_version},
               subject
             )

    assert :ok = Conversations.validate_reference(account.tenant.id, active_conversation.id)
    assert :ok = Conversations.validate_reference(account.tenant.id, archived_conversation.id)

    assert {:error, :not_found} =
             Conversations.validate_reference(account.tenant.id, other_account.conversation.id)

    assert {:error, :not_found} =
             Conversations.validate_reference(account.tenant.id, Ecto.UUID.generate())

    assert {:error, :not_found} =
             Conversations.validate_reference("not-a-tenant-id", active_conversation.id)

    assert Conversations.retention_scope_ids(account.tenant.id) ==
             Enum.sort([
               account.conversation.id,
               active_conversation.id,
               archived_conversation.id
             ])

    assert Conversations.retention_scope_ids(other_account.tenant.id) == [
             other_account.conversation.id
           ]

    assert Conversations.retention_scope_ids("not-a-tenant-id") == []
  end

  test "erasure owner APIs require a caller-owned transaction" do
    account = Fixtures.account_fixture()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:error, :transaction_required} =
             Conversations.archive_for_erasure(
               account.tenant.id,
               account.conversation.id,
               timestamp
             )

    assert {:error, :transaction_required} =
             Conversations.remove_user_memberships_for_erasure(
               account.tenant.id,
               account.user.id,
               timestamp
             )
  end

  test "erasure owner APIs return counts and enforce tenant scope" do
    account = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, conversation} =
             Conversations.create(
               %{
                 title: "Erasure scope",
                 kind: "group",
                 visibility: "private",
                 member_ids: [member.user.id]
               },
               subject
             )

    assert {:ok, %{archive_count: 1, membership_count: 1}} =
             Repo.transaction(fn ->
               assert {:ok, 0} =
                        Conversations.archive_for_erasure(
                          other.tenant.id,
                          conversation.id,
                          timestamp
                        )

               assert {:ok, 0} =
                        Conversations.remove_user_memberships_for_erasure(
                          other.tenant.id,
                          member.user.id,
                          timestamp
                        )

               {:ok, archive_count} =
                 Conversations.archive_for_erasure(
                   account.tenant.id,
                   conversation.id,
                   timestamp
                 )

               {:ok, membership_count} =
                 Conversations.remove_user_memberships_for_erasure(
                   account.tenant.id,
                   member.user.id,
                   timestamp
                 )

               %{archive_count: archive_count, membership_count: membership_count}
             end)

    assert Repo.get!(Conversation, conversation.id).archived_at == timestamp

    assert Repo.get_by!(Membership,
             tenant_id: account.tenant.id,
             conversation_id: conversation.id,
             user_id: member.user.id
           ).left_at == timestamp

    refute Repo.get!(Conversation, other.conversation.id).archived_at
  end

  test "erasure owner API writes roll back with the caller transaction" do
    account = Fixtures.account_fixture()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    membership =
      Repo.get_by!(Membership,
        tenant_id: account.tenant.id,
        conversation_id: account.conversation.id,
        user_id: account.user.id
      )

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, 1} =
                        Conversations.archive_for_erasure(
                          account.tenant.id,
                          account.conversation.id,
                          timestamp
                        )

               assert {:ok, 1} =
                        Conversations.remove_user_memberships_for_erasure(
                          account.tenant.id,
                          account.user.id,
                          timestamp
                        )

               Repo.rollback(:forced_rollback)
             end)

    refute Repo.get!(Conversation, account.conversation.id).archived_at
    refute Repo.get!(Membership, membership.id).left_at
  end
end
