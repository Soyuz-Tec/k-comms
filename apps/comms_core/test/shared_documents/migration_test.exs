defmodule CommsCore.SharedDocuments.MigrationTest.MigrationRepo do
  use Ecto.Repo, otp_app: :comms_core, adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.SharedDocuments.MigrationTest do
  use ExUnit.Case, async: false
  alias CommsCore.SharedDocuments.MigrationTest.MigrationRepo
  alias Ecto.Adapters.SQL
  @moduletag :integration
  @moduletag :release
  @version 20_261_006_000_500

  setup do
    base = CommsCore.Repo.config()
    database = "k_comms_document_migration_" <> String.replace(Ecto.UUID.generate(), "-", "")

    storage =
      base
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.put(:database, database)

    config =
      storage
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:migration_primary_key, Keyword.fetch!(base, :migration_primary_key))
      |> Keyword.put(:migration_foreign_key, Keyword.fetch!(base, :migration_foreign_key))

    assert :ok = Ecto.Adapters.Postgres.storage_up(storage)
    assert {:ok, repo} = MigrationRepo.start_link(config)
    Process.unlink(repo)
    previous = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(previous)
      if Process.alive?(repo), do: GenServer.stop(repo)
      assert :ok = Ecto.Adapters.Postgres.storage_down(storage)
    end)

    Code.require_file(
      Application.app_dir(
        :comms_core,
        "priv/repo/migrations/20261006000500_add_shared_documents.exs"
      )
    )

    # The additive migration consumes only the existing owner reference key.
    SQL.query!(
      MigrationRepo,
      "CREATE TABLE conversations (id uuid PRIMARY KEY, tenant_id uuid NOT NULL, title text NOT NULL, UNIQUE (id, tenant_id))",
      []
    )

    tenant = Ecto.UUID.generate()
    conversation = Ecto.UUID.generate()

    SQL.query!(
      MigrationRepo,
      "INSERT INTO conversations VALUES ($1::text::uuid, $2::text::uuid, 'Prior owner sentinel')",
      [conversation, tenant]
    )

    %{tenant: tenant, conversation: conversation}
  end

  test "the actual additive migration preserves prior rows and down refuses content plus erased generation fences",
       context do
    migration = CommsCore.Repo.Migrations.AddSharedDocuments
    assert :ok = Ecto.Migrator.up(MigrationRepo, @version, migration, log: false)

    assert [["Prior owner sentinel"]] =
             SQL.query!(MigrationRepo, "SELECT title FROM conversations", []).rows

    document = Ecto.UUID.generate()
    client = Ecto.UUID.generate()
    operation = Ecto.UUID.generate()

    SQL.query!(
      MigrationRepo,
      "INSERT INTO shared_documents (id, tenant_id, conversation_id, client_document_id, title, content, author_user_ids, version, inserted_at, updated_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, 'Owned title', 'Owned private body', ARRAY[$5::text::uuid], 1, NOW(), NOW())",
      [document, context.tenant, context.conversation, client, Ecto.UUID.generate()]
    )

    SQL.query!(
      MigrationRepo,
      "INSERT INTO shared_document_operations (id, tenant_id, conversation_id, document_id, actor_user_id, actor_device_id, client_operation_id, generation, version, kind, input, payload, inserted_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5::text::uuid, $6::text::uuid, $7::text::uuid, 1, 1, 'create', '{\"title\":\"Owned title\"}', '{}', NOW())",
      [
        operation,
        context.tenant,
        context.conversation,
        document,
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        client
      ]
    )

    assert_raise Postgrex.Error, ~r/shared documents rollback refused/, fn ->
      Ecto.Migrator.down(MigrationRepo, @version, migration, log: false)
    end

    assert [["Owned private body", 1]] =
             SQL.query!(MigrationRepo, "SELECT content, generation FROM shared_documents", []).rows

    assert [[1]] =
             SQL.query!(MigrationRepo, "SELECT count(*) FROM shared_document_operations", []).rows

    # Even after private payloads and every operation are gone, the retained
    # generation fence still requires the owner capability and migration.
    SQL.query!(MigrationRepo, "DELETE FROM shared_document_operations", [])

    SQL.query!(
      MigrationRepo,
      "UPDATE shared_documents SET content = '', title = 'Erased document', author_user_ids = '{}', erased_at = NOW(), generation = 2",
      []
    )

    assert_raise Postgrex.Error, ~r/shared documents rollback refused/, fn ->
      Ecto.Migrator.down(MigrationRepo, @version, migration, log: false)
    end

    assert [["", 2]] =
             SQL.query!(MigrationRepo, "SELECT content, generation FROM shared_documents", []).rows

    SQL.query!(MigrationRepo, "DELETE FROM shared_documents", [])
    assert :ok = Ecto.Migrator.down(MigrationRepo, @version, migration, log: false)

    assert [[nil, nil]] =
             SQL.query!(
               MigrationRepo,
               "SELECT to_regclass('shared_documents'), to_regclass('shared_document_operations')",
               []
             ).rows

    assert [["Prior owner sentinel"]] =
             SQL.query!(MigrationRepo, "SELECT title FROM conversations", []).rows
  end
end
