defmodule CommsCore.ConversationGuestAccessMigrationTest.MigrationRepo do
  use Ecto.Repo,
    otp_app: :comms_core,
    adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.ConversationGuestAccessMigrationTest do
  use ExUnit.Case, async: false

  alias CommsCore.ConversationGuestAccessMigrationTest.MigrationRepo
  alias Ecto.Adapters.SQL

  @pre_guest_schema_version 20_260_715_000_400
  @guest_identity_schema_version 20_260_724_000_160
  @guest_session_identity_index_version 20_260_724_000_165
  @guest_access_schema_version 20_260_724_000_170
  @conversion_digest_schema_version 20_260_724_000_180
  @guest_access_repair_schema_version 20_260_724_000_190

  setup do
    database =
      "k_comms_guest_upgrade_" <>
        (Ecto.UUID.generate() |> String.replace("-", ""))

    base_config = CommsCore.Repo.config()

    storage_config =
      base_config
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.put(:database, database)

    repo_config =
      storage_config
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(
        :migration_primary_key,
        Keyword.fetch!(base_config, :migration_primary_key)
      )
      |> Keyword.put(
        :migration_foreign_key,
        Keyword.fetch!(base_config, :migration_foreign_key)
      )

    assert :ok = Ecto.Adapters.Postgres.storage_up(storage_config)
    assert {:ok, repo} = MigrationRepo.start_link(repo_config)
    Process.unlink(repo)

    previous_compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(previous_compiler_options)
      if Process.alive?(repo), do: GenServer.stop(repo)
      assert :ok = Ecto.Adapters.Postgres.storage_down(storage_config)
    end)

    %{repo: MigrationRepo}
  end

  test "fresh migrations install the exact guest access constraints and indexes", %{repo: repo} do
    migrate_guest_schema_to(repo, @guest_access_repair_schema_version)

    assert_repaired_schema(repo)
    fixture = seed_guest_link_scope(repo)
    ownership_fixture = seed_guest_admission_ownership_scope(repo, fixture)

    assert_raise Postgrex.Error,
                 ~r/conversation_guest_links_conversion_verification_digest_check/,
                 fn ->
                   insert_guest_link(repo, fixture, "fresh@example.test", nil)
                 end

    assert_guest_admission_ownership_rejections(repo, ownership_fixture)
  end

  test "upgrade repairs applied guest schema drift and remains safe across rollback and reapply",
       %{
         repo: repo
       } do
    migrate_guest_schema_to(repo, @guest_access_schema_version)

    SQL.query!(
      repo,
      "ALTER TABLE conversation_guest_links DROP COLUMN conversion_email"
    )

    migrate_guest_schema_to(repo, @conversion_digest_schema_version)

    assert [["conversion_email"], ["conversion_verification_digest"]] =
             rows(
               repo,
               """
               SELECT column_name
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'conversation_guest_links'
                 AND column_name IN ('conversion_email', 'conversion_verification_digest')
               ORDER BY column_name
               """,
               []
             )

    install_applied_schema_drift(repo)

    assert [
             [
               "f",
               ["tenant_id", "guest_link_id"],
               "conversation_guest_links",
               ["tenant_id", "id"],
               true
             ]
           ] =
             constraint_signature(
               repo,
               "conversation_guest_admissions",
               "conversation_guest_admissions_tenant_link_fk"
             )

    assert [
             [
               "f",
               ["tenant_id", "membership_id"],
               "conversation_memberships",
               ["tenant_id", "id"],
               true
             ]
           ] =
             constraint_signature(
               repo,
               "conversation_guest_admissions",
               "conversation_guest_admissions_tenant_membership_fk"
             )

    assert [
             [
               "f",
               ["tenant_id", "session_id"],
               "sessions",
               ["tenant_id", "id"],
               true
             ]
           ] =
             constraint_signature(
               repo,
               "conversation_guest_admissions",
               "conversation_guest_admissions_tenant_session_fk"
             )

    fixture = seed_guest_link_scope(repo)
    link_id = insert_guest_link(repo, fixture, "legacy@example.test", nil)

    migrate_guest_schema_to(repo, @guest_access_repair_schema_version)

    assert_repaired_schema(repo)
    ownership_fixture = seed_guest_admission_ownership_scope(repo, fixture)
    assert_guest_admission_ownership_rejections(repo, ownership_fixture)

    assert [[nil, nil]] =
             rows(
               repo,
               """
               SELECT conversion_email, conversion_verification_digest
               FROM conversation_guest_links
               WHERE id = $1::text::uuid
               """,
               [link_id]
             )

    Ecto.Migrator.run(repo, migrations_path(), :down, step: 1, log: false)
    assert_repaired_schema(repo)
    assert_guest_admission_ownership_rejections(repo, ownership_fixture)

    migrate_guest_schema_to(repo, @guest_access_repair_schema_version)
    assert_repaired_schema(repo)
  end

  defp migrate_guest_schema_to(repo, version) do
    Ecto.Migrator.run(
      repo,
      migrations_path(),
      :up,
      to: @pre_guest_schema_version,
      log: false
    )

    Ecto.Migrator.run(
      repo,
      guest_migrations(),
      :up,
      to: version,
      log: false
    )
  end

  defp migrations_path do
    Application.app_dir(:comms_core, "priv/repo/migrations")
  end

  defp guest_migrations do
    [
      {@guest_identity_schema_version,
       load_migration(
         "20260724000160_add_guest_identity_expiry.exs",
         CommsCore.Repo.Migrations.AddGuestIdentityExpiry
       )},
      {@guest_session_identity_index_version,
       load_migration(
         "20260724000165_add_guest_admission_session_identity_index.exs",
         CommsCore.Repo.Migrations.AddGuestAdmissionSessionIdentityIndex
       )},
      {@guest_access_schema_version,
       load_migration(
         "20260724000170_add_conversation_guest_access.exs",
         CommsCore.Repo.Migrations.AddConversationGuestAccess
       )},
      {@conversion_digest_schema_version,
       load_migration(
         "20260724000180_add_guest_conversion_verification_digest.exs",
         CommsCore.Repo.Migrations.AddGuestConversionVerificationDigest
       )},
      {@guest_access_repair_schema_version,
       load_migration(
         "20260724000190_repair_conversation_guest_access_constraints.exs",
         CommsCore.Repo.Migrations.RepairConversationGuestAccessConstraints
       )}
    ]
  end

  defp load_migration(file, module) do
    Code.require_file(Path.join(migrations_path(), file))
    module
  end

  defp install_applied_schema_drift(repo) do
    SQL.query!(
      repo,
      """
      ALTER TABLE conversation_guest_admissions
      DROP CONSTRAINT conversation_guest_admissions_tenant_link_fk,
      DROP CONSTRAINT conversation_guest_admissions_tenant_membership_fk,
      DROP CONSTRAINT conversation_guest_admissions_tenant_session_fk
      """
    )

    SQL.query!(
      repo,
      """
      ALTER TABLE conversation_guest_admissions
      ADD CONSTRAINT conversation_guest_admissions_tenant_link_fk
      FOREIGN KEY (tenant_id, guest_link_id)
      REFERENCES conversation_guest_links (tenant_id, id),
      ADD CONSTRAINT conversation_guest_admissions_tenant_membership_fk
      FOREIGN KEY (tenant_id, membership_id)
      REFERENCES conversation_memberships (tenant_id, id),
      ADD CONSTRAINT conversation_guest_admissions_tenant_session_fk
      FOREIGN KEY (tenant_id, session_id)
      REFERENCES sessions (tenant_id, id)
      """
    )

    for statement <- [
          "ALTER TABLE conversation_guest_links " <>
            "DROP CONSTRAINT conversation_guest_links_digest_check",
          "ALTER TABLE conversation_guest_admissions " <>
            "DROP CONSTRAINT conversation_guest_admissions_expiry_check",
          "ALTER TABLE conversation_guest_admissions " <>
            "DROP CONSTRAINT conversation_guest_admissions_history_sequence_check",
          "DROP INDEX conversation_guest_links_tenant_conversation_id_unique",
          "DROP INDEX conversation_guest_admissions_membership_id_index",
          "DROP INDEX conversation_memberships_tenant_conversation_user_id_id_unique",
          "DROP INDEX sessions_tenant_user_id_id_unique",
          "ALTER TABLE conversation_guest_links " <>
            "DROP CONSTRAINT conversation_guest_links_conversion_verification_digest_check"
        ] do
      SQL.query!(repo, statement)
    end

    SQL.query!(
      repo,
      """
      ALTER TABLE conversation_guest_links
      ADD CONSTRAINT conversation_guest_links_conversion_verification_digest_check
      CHECK (
        (conversion_email IS NULL AND conversion_verification_digest IS NULL)
        OR (
          conversion_email IS NOT NULL
          AND octet_length(conversion_verification_digest) = 32
        )
      )
      """
    )

    SQL.query!(
      repo,
      "DELETE FROM schema_migrations WHERE version = $1",
      [@guest_session_identity_index_version]
    )
  end

  defp assert_repaired_schema(repo) do
    assert [
             [
               "f",
               ["tenant_id", "conversation_id", "guest_link_id"],
               "conversation_guest_links",
               ["tenant_id", "conversation_id", "id"],
               true
             ]
           ] =
             constraint_signature(
               repo,
               "conversation_guest_admissions",
               "conversation_guest_admissions_tenant_link_fk"
             )

    assert [
             [
               "f",
               ["tenant_id", "conversation_id", "guest_user_id", "membership_id"],
               "conversation_memberships",
               ["tenant_id", "conversation_id", "user_id", "id"],
               true
             ]
           ] =
             constraint_signature(
               repo,
               "conversation_guest_admissions",
               "conversation_guest_admissions_tenant_membership_fk"
             )

    assert [
             [
               "f",
               ["tenant_id", "guest_user_id", "session_id"],
               "sessions",
               ["tenant_id", "user_id", "id"],
               true
             ]
           ] =
             constraint_signature(
               repo,
               "conversation_guest_admissions",
               "conversation_guest_admissions_tenant_session_fk"
             )

    assert_check(
      repo,
      "conversation_guest_links",
      "conversation_guest_links_digest_check",
      "CHECK (octet_length(token_digest) = 32)"
    )

    assert_check(
      repo,
      "conversation_guest_admissions",
      "conversation_guest_admissions_expiry_check",
      "CHECK (expires_at > admitted_at)"
    )

    assert_check(
      repo,
      "conversation_guest_admissions",
      "conversation_guest_admissions_history_sequence_check",
      "CHECK (history_from_sequence >= 1)"
    )

    assert_check(
      repo,
      "conversation_guest_links",
      "conversation_guest_links_conversion_verification_digest_check",
      "CHECK (conversion_email IS NULL AND conversion_verification_digest IS NULL OR " <>
        "conversion_email IS NOT NULL AND conversion_verification_digest IS NOT NULL AND " <>
        "octet_length(conversion_verification_digest) = 32)"
    )

    assert [[true, ["tenant_id", "conversation_id", "id"]]] =
             index_signature(repo, "conversation_guest_links_tenant_conversation_id_unique")

    assert [[true, ["membership_id"]]] =
             index_signature(repo, "conversation_guest_admissions_membership_id_index")

    assert [[true, ["tenant_id", "conversation_id", "user_id", "id"]]] =
             index_signature(
               repo,
               "conversation_memberships_tenant_conversation_user_id_id_unique"
             )

    assert [[true, ["tenant_id", "user_id", "id"]]] =
             index_signature(repo, "sessions_tenant_user_id_id_unique")
  end

  defp assert_check(repo, table, name, expected_definition) do
    assert [["c", ^expected_definition, true]] =
             rows(
               repo,
               """
               SELECT constraint_type.contype::text,
                      pg_get_constraintdef(constraint_type.oid, true),
                      constraint_type.convalidated
               FROM pg_constraint AS constraint_type
               WHERE constraint_type.conrelid = $1::text::regclass
                 AND constraint_type.conname = $2
               """,
               [table, name]
             )
  end

  defp constraint_signature(repo, table, name) do
    rows(
      repo,
      """
      SELECT constraint_type.contype::text,
             ARRAY(
               SELECT attribute.attname
               FROM unnest(constraint_type.conkey) WITH ORDINALITY AS key(attnum, position)
               JOIN pg_attribute AS attribute
                 ON attribute.attrelid = constraint_type.conrelid
                AND attribute.attnum = key.attnum
               ORDER BY key.position
             ),
             target.relname,
             ARRAY(
               SELECT attribute.attname
               FROM unnest(constraint_type.confkey) WITH ORDINALITY AS key(attnum, position)
               JOIN pg_attribute AS attribute
                 ON attribute.attrelid = constraint_type.confrelid
                AND attribute.attnum = key.attnum
               ORDER BY key.position
             ),
             constraint_type.convalidated
      FROM pg_constraint AS constraint_type
      LEFT JOIN pg_class AS target ON target.oid = constraint_type.confrelid
      WHERE constraint_type.conrelid = $1::text::regclass
        AND constraint_type.conname = $2
      """,
      [table, name]
    )
  end

  defp index_signature(repo, name) do
    rows(
      repo,
      """
      SELECT index_type.indisunique,
             ARRAY(
               SELECT attribute.attname
               FROM unnest(index_type.indkey) WITH ORDINALITY AS key(attnum, position)
               JOIN pg_attribute AS attribute
                 ON attribute.attrelid = index_type.indrelid
                AND attribute.attnum = key.attnum
               ORDER BY key.position
             )
      FROM pg_index AS index_type
      JOIN pg_class AS index_relation ON index_relation.oid = index_type.indexrelid
      WHERE index_relation.relname = $1
      """,
      [name]
    )
  end

  defp seed_guest_link_scope(repo) do
    tenant_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO tenants (id, name, slug, status, inserted_at, updated_at)
      VALUES ($1::text::uuid, 'Guest migration tenant', $2, 'active', NOW(), NOW())
      """,
      [tenant_id, "guest-migration-#{String.slice(tenant_id, 0, 8)}"]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO users (
        id, tenant_id, external_subject, display_name, email, status, role,
        lock_version, account_type, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3, 'Migration owner', $4, 'active', 'owner',
        1, 'human', NOW(), NOW()
      )
      """,
      [user_id, tenant_id, "migration-owner-#{user_id}", "migration-#{user_id}@example.test"]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO conversations (
        id, tenant_id, kind, title, visibility, next_sequence, created_by_user_id,
        lock_version, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, 'group', 'Migration room', 'private', 1,
        $3::text::uuid, 1, NOW(), NOW()
      )
      """,
      [conversation_id, tenant_id, user_id]
    )

    %{tenant_id: tenant_id, user_id: user_id, conversation_id: conversation_id}
  end

  defp seed_guest_admission_ownership_scope(repo, fixture) do
    guest_user_id = Ecto.UUID.generate()
    other_user_id = Ecto.UUID.generate()
    other_conversation_id = Ecto.UUID.generate()
    guest_device_id = Ecto.UUID.generate()
    other_device_id = Ecto.UUID.generate()
    guest_session_id = Ecto.UUID.generate()
    other_session_id = Ecto.UUID.generate()
    guest_membership_id = Ecto.UUID.generate()
    cross_conversation_membership_id = Ecto.UUID.generate()
    cross_user_membership_id = Ecto.UUID.generate()

    insert_test_user(repo, fixture.tenant_id, guest_user_id, "Guest owner", "guest")
    insert_test_user(repo, fixture.tenant_id, other_user_id, "Other user", "human")

    insert_test_conversation(
      repo,
      fixture.tenant_id,
      other_conversation_id,
      fixture.user_id,
      "Other migration room"
    )

    insert_test_device(repo, fixture.tenant_id, guest_user_id, guest_device_id)
    insert_test_device(repo, fixture.tenant_id, other_user_id, other_device_id)

    insert_test_session(
      repo,
      fixture.tenant_id,
      guest_user_id,
      guest_device_id,
      guest_session_id
    )

    insert_test_session(
      repo,
      fixture.tenant_id,
      other_user_id,
      other_device_id,
      other_session_id
    )

    insert_test_membership(
      repo,
      fixture.tenant_id,
      fixture.conversation_id,
      guest_user_id,
      guest_membership_id
    )

    insert_test_membership(
      repo,
      fixture.tenant_id,
      other_conversation_id,
      guest_user_id,
      cross_conversation_membership_id
    )

    insert_test_membership(
      repo,
      fixture.tenant_id,
      fixture.conversation_id,
      other_user_id,
      cross_user_membership_id
    )

    %{
      tenant_id: fixture.tenant_id,
      conversation_id: fixture.conversation_id,
      guest_link_id: insert_guest_link(repo, fixture, nil, nil),
      guest_user_id: guest_user_id,
      guest_membership_id: guest_membership_id,
      cross_conversation_membership_id: cross_conversation_membership_id,
      cross_user_membership_id: cross_user_membership_id,
      guest_session_id: guest_session_id,
      other_session_id: other_session_id
    }
  end

  defp assert_guest_admission_ownership_rejections(repo, fixture) do
    assert_raise Postgrex.Error,
                 ~r/conversation_guest_admissions_tenant_membership_fk/,
                 fn ->
                   insert_guest_admission(
                     repo,
                     fixture,
                     fixture.cross_conversation_membership_id,
                     fixture.guest_session_id
                   )
                 end

    assert_raise Postgrex.Error,
                 ~r/conversation_guest_admissions_tenant_membership_fk/,
                 fn ->
                   insert_guest_admission(
                     repo,
                     fixture,
                     fixture.cross_user_membership_id,
                     fixture.guest_session_id
                   )
                 end

    assert_raise Postgrex.Error,
                 ~r/conversation_guest_admissions_tenant_session_fk/,
                 fn ->
                   insert_guest_admission(
                     repo,
                     fixture,
                     fixture.guest_membership_id,
                     fixture.other_session_id
                   )
                 end
  end

  defp insert_guest_admission(repo, fixture, membership_id, session_id) do
    SQL.query!(
      repo,
      """
      INSERT INTO conversation_guest_admissions (
        id, tenant_id, conversation_id, guest_link_id, guest_user_id,
        membership_id, session_id, admitted_at, expires_at,
        history_from_sequence, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid,
        $5::text::uuid, $6::text::uuid, $7::text::uuid, NOW(),
        NOW() + INTERVAL '30 minutes', 1, NOW(), NOW()
      )
      """,
      [
        Ecto.UUID.generate(),
        fixture.tenant_id,
        fixture.conversation_id,
        fixture.guest_link_id,
        fixture.guest_user_id,
        membership_id,
        session_id
      ]
    )
  end

  defp insert_test_user(repo, tenant_id, user_id, display_name, account_type) do
    guest? = account_type == "guest"

    SQL.query!(
      repo,
      """
      INSERT INTO users (
        id, tenant_id, external_subject, display_name, email, status, role,
        lock_version, account_type, guest_expires_at, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3, $4, $5, 'active', 'member',
        1, $6, CASE WHEN $7 THEN NOW() + INTERVAL '1 hour' ELSE NULL END,
        NOW(), NOW()
      )
      """,
      [
        user_id,
        tenant_id,
        "migration-user-#{user_id}",
        display_name,
        "migration-#{user_id}@example.test",
        account_type,
        guest?
      ]
    )
  end

  defp insert_test_conversation(repo, tenant_id, conversation_id, owner_id, title) do
    SQL.query!(
      repo,
      """
      INSERT INTO conversations (
        id, tenant_id, kind, title, visibility, next_sequence, created_by_user_id,
        lock_version, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, 'group', $3, 'private', 1,
        $4::text::uuid, 1, NOW(), NOW()
      )
      """,
      [conversation_id, tenant_id, title, owner_id]
    )
  end

  defp insert_test_device(repo, tenant_id, user_id, device_id) do
    SQL.query!(
      repo,
      """
      INSERT INTO devices (
        id, tenant_id, user_id, name, platform, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid,
        'Migration browser', 'test', NOW(), NOW()
      )
      """,
      [device_id, tenant_id, user_id]
    )
  end

  defp insert_test_session(repo, tenant_id, user_id, device_id, session_id) do
    SQL.query!(
      repo,
      """
      INSERT INTO sessions (
        id, tenant_id, user_id, device_id, refresh_token_hash, expires_at,
        last_used_at, absolute_expires_at, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5,
        NOW() + INTERVAL '1 hour', NOW(), NOW() + INTERVAL '1 hour', NOW(), NOW()
      )
      """,
      [session_id, tenant_id, user_id, device_id, :crypto.strong_rand_bytes(32)]
    )
  end

  defp insert_test_membership(repo, tenant_id, conversation_id, user_id, membership_id) do
    SQL.query!(
      repo,
      """
      INSERT INTO conversation_memberships (
        id, tenant_id, conversation_id, user_id, role, joined_at,
        last_read_sequence, lock_version, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid,
        'member', NOW(), 0, 1, NOW(), NOW()
      )
      """,
      [membership_id, tenant_id, conversation_id, user_id]
    )
  end

  defp insert_guest_link(repo, fixture, conversion_email, conversion_digest) do
    link_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO conversation_guest_links (
        id, tenant_id, conversation_id, created_by_user_id, token_digest,
        conversion_email, conversion_verification_digest, expires_at, max_uses,
        use_count, lock_version, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5,
        $6, $7, NOW() + INTERVAL '1 hour', 1, 0, 1, NOW(), NOW()
      )
      """,
      [
        link_id,
        fixture.tenant_id,
        fixture.conversation_id,
        fixture.user_id,
        :crypto.strong_rand_bytes(32),
        conversion_email,
        conversion_digest
      ]
    )

    link_id
  end

  defp rows(repo, statement, parameters) do
    SQL.query!(repo, statement, parameters).rows
  end
end
