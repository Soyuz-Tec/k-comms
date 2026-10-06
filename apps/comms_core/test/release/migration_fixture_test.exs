defmodule CommsCore.Release.MigrationFixtureTest do
  use ExUnit.Case, async: false

  alias CommsCore.{MigrationFixture, Repo}

  @moduletag :integration
  @moduletag :migration

  test "fixture quiescence fails closed while a real peer remains and never terminates it" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    database = "k_comms_migration_disconnect_" <> suffix

    storage =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :ssl_opts, :socket_dir])

    options =
      storage
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:connect_timeout, 5_000)

    assert {:ok, admin} = Postgrex.start_link(Keyword.put(options, :database, "postgres"))

    try do
      assert [[0]] =
               Postgrex.query!(admin, "SELECT count(*) FROM pg_database WHERE datname = $1", [
                 database
               ]).rows

      assert :ok = Ecto.Adapters.Postgres.storage_up(Keyword.put(storage, :database, database))

      try do
        assert {:ok, peer} = Postgrex.start_link(Keyword.put(options, :database, database))

        try do
          assert [[backend]] = Postgrex.query!(peer, "SELECT pg_backend_pid()", []).rows
          assert {:error, {:peers_remain, 1}} = MigrationFixture.await_no_peers(admin, database)
          assert Process.alive?(peer)
          assert [[^backend]] = Postgrex.query!(peer, "SELECT pg_backend_pid()", []).rows

          assert [[1]] =
                   Postgrex.query!(
                     admin,
                     "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
                     [
                       database
                     ]
                   ).rows
        after
          GenServer.stop(peer)
        end

        assert :ok = MigrationFixture.await_no_peers(admin, database)

        assert [[0]] =
                 Postgrex.query!(
                   admin,
                   "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
                   [
                     database
                   ]
                 ).rows
      after
        assert :ok =
                 Ecto.Adapters.Postgres.storage_down(Keyword.put(storage, :database, database))
      end
    after
      GenServer.stop(admin)
    end
  end
end
