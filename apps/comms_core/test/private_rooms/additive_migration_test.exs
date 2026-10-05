defmodule CommsCore.PrivateRooms.AdditiveMigrationTest.MigrationRepo do
  use Ecto.Repo, otp_app: :comms_core, adapter: Ecto.Adapters.Postgres
end

defmodule CommsCore.PrivateRooms.AdditiveMigrationTest do
  use ExUnit.Case, async: false
  alias CommsCore.PrivateRooms.AdditiveMigrationTest.MigrationRepo, as: R
  alias CommsCore.Accounts.{User, Device, Session, MatrixIdentity, MatrixClientSession}
  alias CommsCore.Conversations.{Conversation, PrivateRoom}
  alias CommsCore.Messaging.PrivateEvent
  @moduletag :integration
  @moduletag :migration
  @identity 20_261_006_001_000
  @rooms 20_261_006_001_100
  @events 20_261_006_001_200
  setup_all do
    # Older parent migrations deliberately use the canonical Repo helper for
    # concurrent indexes. Qualify a truly fresh parent in its own process,
    # then clone that quiescent snapshot so these tests execute ONLY our three
    # additive migrations against real parent indexes and retained fixtures.
    base = CommsCore.Repo.config()
    database = "k_comms_private_parent_" <> String.replace(Ecto.UUID.generate(), "-", "")

    storage =
      base
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.put(:database, database)

    assert :ok = Ecto.Adapters.Postgres.storage_up(storage)
    username = Keyword.get(base, :username, "postgres")
    password = Keyword.get(base, :password, "postgres")

    uri = %URI{
      scheme: "ecto",
      host: Keyword.get(base, :hostname, "localhost"),
      port: Keyword.get(base, :port, 5432),
      userinfo:
        URI.encode(username, &URI.char_unreserved?/1) <>
          ":" <> URI.encode(password, &URI.char_unreserved?/1),
      path: "/" <> database
    }

    {log, exit} =
      System.cmd("mix", ["ecto.migrate", "--to", "20261006000999"],
        cd: Path.expand("../../../..", __DIR__),
        env: [{"DATABASE_URL", URI.to_string(uri)}, {"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert exit == 0, "fresh private parent migration failed: " <> log
    on_exit(fn -> assert :ok = Ecto.Adapters.Postgres.storage_down(storage) end)
    %{baseline_database: database}
  end

  setup %{baseline_database: baseline} do
    storage =
      CommsCore.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.put(
        :database,
        "k_comms_private_upgrade_" <> String.replace(Ecto.UUID.generate(), "-", "")
      )

    config =
      storage
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(
        :migration_primary_key,
        Keyword.fetch!(CommsCore.Repo.config(), :migration_primary_key)
      )
      |> Keyword.put(
        :migration_foreign_key,
        Keyword.fetch!(CommsCore.Repo.config(), :migration_foreign_key)
      )

    assert :ok = Ecto.Adapters.Postgres.storage_up(Keyword.put(storage, :template, baseline))
    {:ok, pid} = R.start_link(config)
    Process.unlink(pid)
    old = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(old)
      if Process.alive?(pid), do: GenServer.stop(pid)
      assert :ok = Ecto.Adapters.Postgres.storage_down(storage)
    end)

    migrate(:up, @events)
    :ok
  end

  test "fresh additive schema preserves readable rooms through empty rollback/reapply" do
    f = fixture()
    assert R.get!(Conversation, f.conversation.id).content_mode == :server_readable
    migrate(:down, @identity - 1)
    migrate(:up, @events)
    assert R.get!(Conversation, f.conversation.id).title == "Legacy readable room"
    assert R.get!(Conversation, f.conversation.id).content_mode == :server_readable
  end

  test "retained identity cleanup and revoked device proof block rollback; completion cannot be fabricated" do
    f = fixture()
    identity = identity(f)

    R.insert!(%MatrixClientSession{
      tenant_id: f.tenant.id,
      user_id: f.user.id,
      device_id: f.device.id,
      session_id: f.session.id,
      matrix_identity_id: identity.id,
      matrix_device_id: "KC_retained",
      state: :revoked
    })

    assert_raise Postgrex.Error, ~r/refusing retained Matrix identities/, fn ->
      migrate(:down, @identity - 1)
    end

    assert R.get!(MatrixIdentity, identity.id).state == :cleanup_pending
  end

  test "provider-purged room with unconfirmed key cleanup remains a rollback hazard" do
    f = fixture()
    room = private(f)

    assert_raise Postgrex.Error, ~r/refusing retained private room lineage/, fn ->
      migrate(:down, @rooms - 1)
    end

    assert R.get!(PrivateRoom, room.id).key_cleanup_state == "unconfirmed"
  end

  test "erased opaque tombstone blocks rollback and exact session/author tuple cannot cross tenant" do
    f = fixture()
    private(f)

    event = %PrivateEvent{
      tenant_id: f.tenant.id,
      conversation_id: f.conversation.id,
      author_user_id: f.user.id,
      author_device_id: f.device.id,
      author_session_id: f.session.id,
      matrix_room_id: "!scope:example.test",
      matrix_sender: "@scope:example.test",
      membership_epoch: 1,
      generation: 1,
      sequence: 1,
      transaction_id: "retained",
      state: :erased
    }

    saved = R.insert!(event)
    other = fixture()

    assert_raise Ecto.ConstraintError, fn ->
      R.insert!(%{
        event
        | id: nil,
          sequence: 2,
          transaction_id: "foreign",
          author_session_id: other.session.id
      })
    end

    assert_raise Postgrex.Error, ~r/refusing retained opaque events/, fn ->
      migrate(:down, @events - 1)
    end

    assert R.get!(PrivateEvent, saved.id).content == nil
  end

  defp migrate(direction, to),
    do:
      Ecto.Migrator.run(R, Application.app_dir(:comms_core, "priv/repo/migrations"), direction,
        to: to,
        log: false
      )

  defp fixture do
    now = DateTime.utc_now()
    suffix = String.replace(Ecto.UUID.generate(), "-", "")

    tenant =
      R.insert!(%CommsCore.Administration.Tenant{
        name: "Private schema scope",
        slug: "private-" <> suffix
      })

    user =
      R.insert!(%User{
        tenant_id: tenant.id,
        external_subject: "local:" <> suffix,
        email: suffix <> "@example.test",
        display_name: "Schema user",
        password_hash: "migration-auth-placeholder"
      })

    device =
      R.insert!(%Device{
        tenant_id: tenant.id,
        user_id: user.id,
        name: "Schema device",
        platform: "test"
      })

    session =
      R.insert!(%Session{
        tenant_id: tenant.id,
        user_id: user.id,
        device_id: device.id,
        refresh_token_hash: :crypto.strong_rand_bytes(32),
        expires_at: DateTime.add(now, 600, :second),
        absolute_expires_at: DateTime.add(now, 600, :second),
        last_used_at: now
      })

    conversation =
      R.insert!(%Conversation{
        tenant_id: tenant.id,
        created_by_user_id: user.id,
        kind: :group,
        visibility: :private,
        title: "Legacy readable room"
      })

    %{tenant: tenant, user: user, device: device, session: session, conversation: conversation}
  end

  defp identity(f),
    do:
      R.insert!(%MatrixIdentity{
        tenant_id: f.tenant.id,
        user_id: f.user.id,
        issuer: "https://matrix.example.test",
        matrix_user_id: "@" <> f.user.id <> ":example.test",
        state: :cleanup_pending
      })

  defp private(f) do
    R.update!(Ecto.Changeset.change(f.conversation, content_mode: :matrix_e2ee))

    R.insert!(%PrivateRoom{
      tenant_id: f.tenant.id,
      conversation_id: f.conversation.id,
      creator_user_id: f.user.id,
      provider_issuer: "https://matrix.example.test",
      provider_server_name: "example.test",
      control_matrix_user_id: "@control:example.test",
      room_alias: "#" <> f.conversation.id <> ":example.test",
      matrix_room_id: "!" <> f.conversation.id <> ":example.test",
      input_fingerprint: :crypto.strong_rand_bytes(32),
      historical_user_ids: [f.user.id],
      matrix_members: %{
        f.user.id => %{
          "issuer" => "https://matrix.example.test",
          "matrix_user_id" => "@scope:example.test"
        }
      },
      state: :provider_purged,
      purge_id: "retained-proof",
      provider_purged_at: DateTime.utc_now()
    })
  end
end
