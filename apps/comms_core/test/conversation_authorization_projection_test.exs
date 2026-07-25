defmodule CommsCore.ConversationAuthorizationProjectionTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Conversations
  alias CommsCore.Conversations.Membership
  alias Ecto.Adapters.SQL
  alias CommsTestSupport.Fixtures

  test "keeps active membership authorization composable and owner-scoped" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, active} =
             Conversations.create(
               %{kind: "group", title: "Authorized projection"},
               subject
             )

    assert {:ok, departed} =
             Conversations.create(
               %{kind: "group", title: "Departed projection"},
               subject
             )

    departed_membership =
      Repo.get_by!(Membership,
        tenant_id: account.tenant.id,
        conversation_id: departed.id,
        user_id: account.user.id
      )

    departed_membership
    |> Membership.changeset(%{
      left_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()

    assert {:ok, archived} =
             Conversations.create(
               %{kind: "group", title: "Archived projection"},
               subject
             )

    assert {:ok, _archived} =
             Conversations.archive(
               archived.id,
               %{version: archived.lock_version},
               subject
             )

    foreign = Fixtures.account_fixture()
    assert {:ok, grant} = Accounts.access_grant(subject)

    query = Conversations.active_membership_authorization_query(grant)
    {sql, params} = SQL.to_sql(:all, Repo, query)

    assert sql =~ ~s(JOIN "conversation_memberships")
    assert sql =~ ~s(c0."archived_at" IS NULL)
    assert sql =~ ~s("conversation_ephemeral_rooms")
    assert length(params) >= 2

    authorizations = Repo.all(query)
    authorized_ids = MapSet.new(authorizations, & &1.conversation_id)

    assert MapSet.member?(authorized_ids, account.conversation.id)
    assert MapSet.member?(authorized_ids, active.id)
    refute MapSet.member?(authorized_ids, departed.id)
    refute MapSet.member?(authorized_ids, archived.id)
    refute MapSet.member?(authorized_ids, foreign.conversation.id)

    assert Enum.all?(authorizations, &(&1.membership_role == :owner))
    assert Conversations.active_conversation_member?(grant, active.id)
    refute Conversations.active_conversation_member?(grant, departed.id)
    refute Conversations.active_conversation_member?(grant, archived.id)
    refute Conversations.active_conversation_member?(grant, foreign.conversation.id)
    refute Conversations.active_conversation_member?(grant, "not-a-uuid")
  end

  test "active membership authorization index is valid and selected by the planner" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, grant} = Accounts.access_grant(subject)

    assert %{rows: [[true]]} =
             SQL.query!(
               Repo,
               """
               SELECT index_record.indisvalid
               FROM pg_catalog.pg_index AS index_record
               JOIN pg_catalog.pg_class AS index_relation
                 ON index_relation.oid = index_record.indexrelid
               JOIN pg_catalog.pg_namespace AS index_namespace
                 ON index_namespace.oid = index_relation.relnamespace
               WHERE index_namespace.nspname = current_schema()
                 AND index_relation.relname = 'conversation_memberships_active_user_index'
               """,
               []
             )

    SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])

    assert %{rows: plan_rows} =
             SQL.query!(
               Repo,
               """
               EXPLAIN (COSTS OFF)
               SELECT conversation_id
               FROM conversation_memberships
               WHERE tenant_id = $1
                 AND user_id = $2
                 AND left_at IS NULL
               """,
               [Ecto.UUID.dump!(grant.tenant_id), Ecto.UUID.dump!(grant.user_id)]
             )

    plan = Enum.map_join(plan_rows, "\n", &List.first/1)
    assert plan =~ "conversation_memberships_active_user_index"
  end
end
