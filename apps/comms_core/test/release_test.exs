defmodule CommsCore.ReleaseTest do
  use ExUnit.Case, async: false

  alias CommsCore.Release

  @database_client "k_comms/one_shot/worker/migrate-pod-a1b2c3"
  @default_settings %{lock_timeout_ms: 5_000, statement_timeout_ms: 300_000}
  @guest_capabilities "guest_identity_v1,guest_admission_expiry_worker_v1"

  test "migration environment requires one-shot purpose and bounded ordered timeouts" do
    environment = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_MIGRATION_REQUIRE_QUIESCENCE" => "true"
    }

    assert {:ok, @default_settings} =
             Release.validate_migration_environment(&Map.get(environment, &1))

    assert {:ok, %{lock_timeout_ms: 7_500, statement_timeout_ms: 420_000}} =
             Release.validate_migration_environment(
               &(environment
                 |> Map.merge(%{
                   "K_COMMS_MIGRATION_LOCK_TIMEOUT_MS" => "7500",
                   "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS" => "420000"
                 })
                 |> Map.get(&1))
             )

    assert {:error, :one_shot_runtime_required} =
             Release.validate_migration_environment(
               &(environment
                 |> Map.put("K_COMMS_RUNTIME_PURPOSE", "application")
                 |> Map.get(&1))
             )

    assert {:error, :migration_quiescence_confirmation_required} =
             Release.validate_migration_environment(
               &(environment
                 |> Map.delete("K_COMMS_MIGRATION_REQUIRE_QUIESCENCE")
                 |> Map.get(&1))
             )

    for value <- ["999", "30001", "5 seconds"] do
      assert {:error, :migration_lock_timeout_invalid} =
               Release.validate_migration_environment(
                 &(environment
                   |> Map.put("K_COMMS_MIGRATION_LOCK_TIMEOUT_MS", value)
                   |> Map.get(&1))
               )
    end

    for value <- ["59999", "900001", "unbounded"] do
      assert {:error, :migration_statement_timeout_invalid} =
               Release.validate_migration_environment(
                 &(environment
                   |> Map.put("K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS", value)
                   |> Map.get(&1))
               )
    end
  end

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

  test "rollback environment requires an identified target and explicit quiescence for legacy targets" do
    compatible = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_ROLLBACK_TARGET_REVISION" => "sha-1234abcd",
      "K_COMMS_ROLLBACK_TARGET_CAPABILITIES" => @guest_capabilities
    }

    assert {:ok, context} =
             Release.validate_guest_rollback_environment(&Map.get(compatible, &1))

    assert context.target_revision == "sha-1234abcd"
    assert MapSet.member?(context.capabilities, "guest_identity_v1")
    assert MapSet.member?(context.capabilities, "guest_admission_expiry_worker_v1")

    legacy =
      compatible
      |> Map.put("K_COMMS_ROLLBACK_TARGET_CAPABILITIES", "")
      |> Map.put("K_COMMS_ROLLBACK_WRITES_QUIESCED", "true")

    assert {:ok, legacy_context} =
             Release.validate_guest_rollback_environment(&Map.get(legacy, &1))

    assert legacy_context.capabilities == MapSet.new()

    assert {:error, :rollback_writes_quiescence_confirmation_required} =
             Release.validate_guest_rollback_environment(
               &(legacy
                 |> Map.delete("K_COMMS_ROLLBACK_WRITES_QUIESCED")
                 |> Map.get(&1))
             )

    assert {:error, :rollback_target_revision_required} =
             Release.validate_guest_rollback_environment(
               &(compatible
                 |> Map.put("K_COMMS_ROLLBACK_TARGET_REVISION", "unsafe revision\nvalue")
                 |> Map.get(&1))
             )
  end

  test "rollback hazard result accepts compatible targets or a clean legacy database only" do
    compatible = %{
      target_revision: "sha-compatible",
      capabilities: @guest_capabilities |> String.split(",") |> MapSet.new()
    }

    assert %{guest_users: 4, active_guest_expiry_jobs: 2} =
             Release.assert_guest_rollback_hazards!(
               %{guest_users: 4, active_guest_expiry_jobs: 2},
               compatible
             )

    legacy = %{target_revision: "sha-legacy", capabilities: MapSet.new()}

    assert %{guest_users: 0, active_guest_expiry_jobs: 0} =
             Release.assert_guest_rollback_hazards!(
               %{guest_users: 0, active_guest_expiry_jobs: 0},
               legacy
             )

    assert_raise RuntimeError,
                 ~r/target sha-legacy lacks guest_identity_v1.*1 persisted guest user row/s,
                 fn ->
                   Release.assert_guest_rollback_hazards!(
                     %{guest_users: 1, active_guest_expiry_jobs: 0},
                     legacy
                   )
                 end

    assert_raise RuntimeError,
                 ~r/2 active guest expiry job\(s\)/,
                 fn ->
                   Release.assert_guest_rollback_hazards!(
                     %{guest_users: 0, active_guest_expiry_jobs: 2},
                     legacy
                   )
                 end
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
  end

  test "each runtime boot gets a bounded unique database application name" do
    runtime_environment = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/k_comms_runtime_config_test",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "K_COMMS_ROLE" => "migration-operator-role",
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_INSTANCE_ID" => "migration-host-with-a-stable-instance-identifier",
      "PUBLIC_APP_URL" => "https://comms.example.test",
      "PASSWORD_RECOVERY_SIGNING_KEY" => String.duplicate("r", 32),
      "S3_ACCESS_KEY_ID" => "runtime-config-test-access",
      "S3_SECRET_ACCESS_KEY" => "runtime-config-test-secret"
    }

    previous_environment =
      Map.new(runtime_environment, fn {variable, _value} ->
        {variable, System.get_env(variable)}
      end)

    Enum.each(runtime_environment, fn {variable, value} -> System.put_env(variable, value) end)

    on_exit(fn ->
      Enum.each(previous_environment, fn {variable, value} ->
        restore_environment(variable, value)
      end)
    end)

    first = runtime_database_application_name!()
    second = runtime_database_application_name!()

    assert byte_size(first) <= 63
    assert byte_size(second) <= 63
    assert first != second

    expected_instance_digest =
      :sha256
      |> :crypto.hash(runtime_environment["K_COMMS_INSTANCE_ID"])
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    assert ["k_comms", "one_shot", "migration-op", first_nonce, ^expected_instance_digest] =
             String.split(first, "/")

    assert ["k_comms", "one_shot", "migration-op", second_nonce, ^expected_instance_digest] =
             String.split(second, "/")

    assert first_nonce =~ ~r/^[A-Za-z0-9_-]{16}$/
    assert second_nonce =~ ~r/^[A-Za-z0-9_-]{16}$/
    assert first_nonce != second_nonce
  end

  defp runtime_database_application_name! do
    runtime_config =
      Path.expand("../../../config/runtime.exs", __DIR__)
      |> Config.Reader.read!(env: :prod)

    runtime_config
    |> Keyword.fetch!(:comms_core)
    |> Keyword.fetch!(CommsCore.Repo)
    |> Keyword.fetch!(:parameters)
    |> Keyword.fetch!(:application_name)
  end

  defp restore_environment(variable, nil), do: System.delete_env(variable)
  defp restore_environment(variable, value), do: System.put_env(variable, value)
end
