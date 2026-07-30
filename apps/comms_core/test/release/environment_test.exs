defmodule CommsCore.Release.EnvironmentTest do
  use ExUnit.Case, async: true

  alias CommsCore.Release

  @guest_capabilities "guest_identity_v1,guest_admission_expiry_worker_v1"
  @communication_capabilities Enum.join(
                                [
                                  @guest_capabilities,
                                  "instant_room_lifecycle_v1",
                                  "instant_room_presence_lease_v1",
                                  "instant_room_expiry_worker_v1",
                                  "conversation_only_human_v1"
                                ],
                                ","
                              )

  @moduletag :unit
  @moduletag :release

  test "migration environment requires one-shot purpose and bounded ordered timeouts" do
    environment = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_MIGRATION_REQUIRE_QUIESCENCE" => "true"
    }

    assert {:ok, %{lock_timeout_ms: 5_000, statement_timeout_ms: 300_000}} =
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

  test "qualification tenant environment is one-shot, confirmed, and derived from a bounded id" do
    qualification_id = String.duplicate("a", 32)

    environment = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_QUALIFICATION_CONFIRMATION" => "local-release-qualification-tenant-v1",
      "K_COMMS_QUALIFICATION_ACTION" => "create",
      "K_COMMS_QUALIFICATION_ID" => qualification_id,
      "K_COMMS_QUALIFICATION_PASSWORD" => String.duplicate("Qx9!", 12)
    }

    assert {:ok, context} =
             Release.validate_qualification_environment(&Map.get(environment, &1))

    assert context.action == :create
    assert context.attrs.tenant_slug == "k-comms-qualification-#{qualification_id}"

    assert context.attrs.email ==
             "k-comms-qualification-owner+#{qualification_id}@example.test"

    assert {:ok, %{action: :delete}} =
             Release.validate_qualification_environment(
               &(environment
                 |> Map.put("K_COMMS_QUALIFICATION_ACTION", "delete")
                 |> Map.delete("K_COMMS_QUALIFICATION_PASSWORD")
                 |> Map.get(&1))
             )

    for {name, value, expected_error} <- [
          {"K_COMMS_RUNTIME_PURPOSE", "application", :one_shot_runtime_required},
          {"K_COMMS_QUALIFICATION_CONFIRMATION", "wrong", :qualification_confirmation_required},
          {"K_COMMS_QUALIFICATION_ACTION", "purge", :qualification_action_invalid},
          {"K_COMMS_QUALIFICATION_ID", "not-a-bounded-id", :qualification_id_invalid},
          {"K_COMMS_QUALIFICATION_PASSWORD", "short", :qualification_password_required}
        ] do
      assert {:error, ^expected_error} =
               Release.validate_qualification_environment(
                 &(environment
                   |> Map.put(name, value)
                   |> Map.get(&1))
               )
    end
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

  test "communication rollback environment requires quiescence for every partial target" do
    compatible = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_ROLLBACK_TARGET_REVISION" => "sha-communication-compatible",
      "K_COMMS_ROLLBACK_TARGET_CAPABILITIES" => @communication_capabilities
    }

    assert {:ok, context} =
             Release.validate_communication_rollback_environment(&Map.get(compatible, &1))

    assert context.target_revision == "sha-communication-compatible"
    assert MapSet.member?(context.capabilities, "instant_room_lifecycle_v1")
    assert MapSet.member?(context.capabilities, "instant_room_presence_lease_v1")
    assert MapSet.member?(context.capabilities, "instant_room_expiry_worker_v1")
    assert MapSet.member?(context.capabilities, "conversation_only_human_v1")

    partial =
      Map.put(
        compatible,
        "K_COMMS_ROLLBACK_TARGET_CAPABILITIES",
        @guest_capabilities
      )

    assert {:error, :rollback_writes_quiescence_confirmation_required} =
             Release.validate_communication_rollback_environment(&Map.get(partial, &1))

    assert {:ok, partial_context} =
             Release.validate_communication_rollback_environment(
               &(partial
                 |> Map.put("K_COMMS_ROLLBACK_WRITES_QUIESCED", "true")
                 |> Map.get(&1))
             )

    refute MapSet.member?(partial_context.capabilities, "instant_room_lifecycle_v1")
  end
end
