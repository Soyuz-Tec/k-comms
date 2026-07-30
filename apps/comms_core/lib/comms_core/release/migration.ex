defmodule CommsCore.Release.Migration do
  @moduledoc false

  alias CommsCore.{Repo, Release.Environment}

  @app :comms_core
  @one_shot_database_client_prefix "k_comms/one_shot/"

  def migrate do
    with {:ok, settings} <- Environment.validate_migration(&System.get_env/1) do
      load_app()

      for repo <- Application.fetch_env!(@app, :ecto_repos) do
        {:ok, _, _} =
          Ecto.Migrator.with_repo(repo, fn repo ->
            assert_migration_preflight!(repo, settings)
            Ecto.Migrator.run(repo, :up, all: true)
          end)
      end
    else
      {:error, reason} -> raise "release migration refused: #{migration_error(reason)}"
    end
  end

  @spec rollback(module(), integer()) :: no_return()
  def rollback(_repo, _version) do
    raise "release schema rollback refused: down migrations are unsupported; " <>
            "restore a verified backup or apply an explicitly reviewed forward repair"
  end

  def assert_migration_preflight!(repo, settings) when is_atom(repo) and is_map(settings) do
    rows = repo.release_migration_preflight!()

    assert_migration_preflight_result!(rows, settings)
  end

  def assert_migration_preflight_result!(
        [
          [
            application_name,
            actual_lock_timeout_ms,
            actual_statement_timeout_ms,
            peer_count
          ]
        ],
        %{
          lock_timeout_ms: expected_lock_timeout_ms,
          statement_timeout_ms: expected_statement_timeout_ms
        }
      )
      when is_binary(application_name) and is_integer(actual_lock_timeout_ms) and
             is_integer(actual_statement_timeout_ms) and is_integer(peer_count) do
    assert_one_shot_database_client!(application_name)

    if actual_lock_timeout_ms != expected_lock_timeout_ms do
      raise "migration preflight failed: PostgreSQL lock_timeout is not the configured bounded value"
    end

    if actual_statement_timeout_ms != expected_statement_timeout_ms do
      raise "migration preflight failed: PostgreSQL statement_timeout is not the configured bounded value"
    end

    assert_peer_count_quiesced!(peer_count)
  end

  def assert_migration_preflight_result!(_rows, _settings) do
    raise "migration preflight failed: PostgreSQL returned an invalid session snapshot"
  end

  def assert_database_quiesced!(repo \\ Repo) when is_atom(repo) do
    rows = repo.release_migration_preflight!()

    assert_database_quiescence_result!(rows)
  end

  def assert_database_quiescence_result!([
        [application_name, _lock_timeout_ms, _statement_timeout_ms, peer_count]
      ])
      when is_binary(application_name) and is_integer(peer_count) do
    assert_one_shot_database_client!(application_name)
    assert_peer_count_quiesced!(peer_count)
  end

  def assert_database_quiescence_result!(_rows) do
    raise "database quiescence check failed: PostgreSQL returned an invalid session snapshot"
  end

  defp assert_one_shot_database_client!(application_name) do
    unless String.starts_with?(application_name, @one_shot_database_client_prefix) do
      raise "database quiescence check failed: the connection is not an identified one-shot runtime"
    end
  end

  defp assert_peer_count_quiesced!(0), do: :ok

  defp assert_peer_count_quiesced!(peer_count) when peer_count > 0 do
    raise "database quiescence check failed: " <>
            "#{peer_count} other client session(s) remain connected; " <>
            "stop edge, worker, application, and other administrative runtimes before continuing"
  end

  defp load_app do
    Application.load(@app)
  end

  defp migration_error(:one_shot_runtime_required), do: "one_shot_runtime_required"

  defp migration_error(:migration_quiescence_confirmation_required),
    do: "K_COMMS_MIGRATION_REQUIRE_QUIESCENCE must be true"

  defp migration_error(:migration_lock_timeout_invalid),
    do: "K_COMMS_MIGRATION_LOCK_TIMEOUT_MS must be an integer from 1000 through 30000"

  defp migration_error(:migration_statement_timeout_invalid),
    do: "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS must be an integer from 60000 through 900000"

  defp migration_error(:migration_statement_timeout_must_exceed_lock_timeout),
    do: "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS must exceed K_COMMS_MIGRATION_LOCK_TIMEOUT_MS"

  defp migration_error(reason) when is_atom(reason), do: Atom.to_string(reason)
end
