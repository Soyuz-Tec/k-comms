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

  test "active membership authorization index is live and matches the query shape" do
    assert %{
             rows: [
               [
                 true,
                 true,
                 true,
                 false,
                 "btree",
                 ["tenant_id", "user_id", "conversation_id"],
                 "(left_at IS NULL)"
               ]
             ]
           } =
             SQL.query!(
               Repo,
               """
               SELECT
                 index_record.indisvalid,
                 index_record.indisready,
                 index_record.indislive,
                 index_record.indisunique,
                 access_method.amname,
                 ARRAY(
                   SELECT attribute.attname
                   FROM unnest(index_record.indkey)
                     WITH ORDINALITY AS indexed_column(attnum, position)
                   JOIN pg_catalog.pg_attribute AS attribute
                     ON attribute.attrelid = index_record.indrelid
                    AND attribute.attnum = indexed_column.attnum
                   ORDER BY indexed_column.position
                 ),
                 pg_catalog.pg_get_expr(
                   index_record.indpred,
                   index_record.indrelid
                 )
               FROM pg_catalog.pg_index AS index_record
               JOIN pg_catalog.pg_class AS index_relation
                 ON index_relation.oid = index_record.indexrelid
               JOIN pg_catalog.pg_namespace AS index_namespace
                 ON index_namespace.oid = index_relation.relnamespace
               JOIN pg_catalog.pg_am AS access_method
                 ON access_method.oid = index_relation.relam
               WHERE index_namespace.nspname = current_schema()
                 AND index_relation.relname = 'conversation_memberships_active_user_index'
               """,
               []
             )
  end
end
