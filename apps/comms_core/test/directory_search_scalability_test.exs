defmodule CommsCore.DirectorySearchScalabilityTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias Ecto.Adapters.SQL
  alias CommsTestSupport.Fixtures

  test "preserves literal substring search for SQL wildcard characters" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    percent = Fixtures.user_fixture(account, %{display_name: "Percent % Person"}).user
    underscore = Fixtures.user_fixture(account, %{display_name: "Under_score Person"}).user
    plain = Fixtures.user_fixture(account, %{display_name: "Plain Person"}).user

    assert {:ok, %{people: percent_people}} =
             Accounts.list_directory_views(%{q: "%"}, subject)

    assert Enum.map(percent_people, & &1.id) == [percent.id]

    assert {:ok, %{people: underscore_people}} =
             Accounts.list_directory_views(%{q: "_"}, subject)

    assert Enum.map(underscore_people, & &1.id) == [underscore.id]

    assert {:ok, %{people: people}} =
             Accounts.list_directory_views(%{q: "PERSON"}, subject)

    assert MapSet.new(Enum.map(people, & &1.id)) ==
             MapSet.new([percent.id, underscore.id, plain.id])
  end

  test "installs a valid trigram index for active-human directory search" do
    assert %{rows: [[true]]} =
             SQL.query!(
               Repo,
               "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')",
               []
             )

    assert %{rows: [[true, index_definition]]} =
             SQL.query!(
               Repo,
               """
               SELECT index_record.indisvalid,
                      pg_get_indexdef(index_record.indexrelid)
               FROM pg_catalog.pg_index AS index_record
               JOIN pg_catalog.pg_class AS index_relation
                 ON index_relation.oid = index_record.indexrelid
               JOIN pg_catalog.pg_namespace AS index_namespace
                 ON index_namespace.oid = index_relation.relnamespace
               WHERE index_namespace.nspname = current_schema()
                 AND index_relation.relname = 'users_active_human_display_name_trgm_index'
               """,
               []
             )

    assert index_definition =~ "USING gin (display_name gin_trgm_ops)"
    assert index_definition =~ "status = 'active'::text"
    assert index_definition =~ "account_type = 'human'::text"
  end
end
