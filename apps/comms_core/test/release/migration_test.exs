defmodule CommsCore.Release.MigrationTest do
  use ExUnit.Case, async: false

  alias CommsCore.Release

  @database_client "k_comms/one_shot/worker/migrate-pod-a1b2c3"
  @default_settings %{lock_timeout_ms: 5_000, statement_timeout_ms: 300_000}

  @moduletag :unit
  @moduletag :release

  test "migration preflight proves timeout settings and database quiescence" do
    assert :ok =
             Release.assert_migration_preflight_result!(
               [[@database_client, 5_000, 300_000, 0]],
               @default_settings
             )

    assert_raise RuntimeError,
                 "migration preflight failed: PostgreSQL lock_timeout is not the configured bounded value",
                 fn ->
                   Release.assert_migration_preflight_result!(
                     [[@database_client, 0, 300_000, 0]],
                     @default_settings
                   )
                 end

    assert_raise RuntimeError,
                 "migration preflight failed: PostgreSQL statement_timeout is not the configured bounded value",
                 fn ->
                   Release.assert_migration_preflight_result!(
                     [[@database_client, 5_000, 0, 0]],
                     @default_settings
                   )
                 end
  end

  test "database quiescence check fails closed for unidentified clients and every peer session" do
    assert :ok =
             Release.assert_database_quiescence_result!([
               [@database_client, 5_000, 300_000, 0]
             ])

    assert_raise RuntimeError,
                 "database quiescence check failed: the connection is not an identified one-shot runtime",
                 fn ->
                   Release.assert_database_quiescence_result!([
                     ["k_comms/application/edge/pod", 5_000, 300_000, 0]
                   ])
                 end

    assert_raise RuntimeError,
                 ~r/3 other client session\(s\) remain connected/,
                 fn ->
                   Release.assert_database_quiescence_result!([
                     [@database_client, 5_000, 300_000, 3]
                   ])
                 end

    assert_raise RuntimeError,
                 "database quiescence check failed: PostgreSQL returned an invalid session snapshot",
                 fn -> Release.assert_database_quiescence_result!([]) end
  end

  test "release schema rollback is unconditionally refused before database access" do
    for version <- [202_607_240_001_90, 202_607_240_001_80, 1] do
      assert_raise RuntimeError,
                   "release schema rollback refused: down migrations are unsupported; " <>
                     "restore a verified backup or apply an explicitly reviewed forward repair",
                   fn -> Release.rollback(CommsCore.Repo, version) end
    end
  end

  test "public rollback helper refuses a normal application runtime before database access" do
    variable = "K_COMMS_RUNTIME_PURPOSE"
    previous = System.get_env(variable)
    System.put_env(variable, "application")

    on_exit(fn -> restore_environment(variable, previous) end)

    assert_raise RuntimeError,
                 "guest rollback compatibility check refused: one_shot_runtime_required",
                 fn -> Release.assert_guest_rollback_compatible!() end

    assert_raise RuntimeError,
                 "communication rollback compatibility check refused: one_shot_runtime_required",
                 fn -> Release.assert_communication_rollback_compatible!() end
  end

  defp restore_environment(variable, nil), do: System.delete_env(variable)
  defp restore_environment(variable, value), do: System.put_env(variable, value)
end
