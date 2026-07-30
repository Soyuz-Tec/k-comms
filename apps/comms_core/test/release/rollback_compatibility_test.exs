defmodule CommsCore.Release.RollbackCompatibilityTest do
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

  test "communication rollback hazards are evaluated per target capability" do
    hazards = %{
      guest_users: 2,
      active_guest_expiry_jobs: 3,
      ephemeral_rooms: 4,
      ephemeral_join_receipts: 9,
      ephemeral_presence_leases: 5,
      active_ephemeral_room_lifecycle_jobs: 6,
      active_ephemeral_room_reconciler_jobs: 7,
      conversation_only_humans: 8
    }

    compatible = %{
      target_revision: "sha-compatible",
      capabilities: @communication_capabilities |> String.split(",") |> MapSet.new()
    }

    assert ^hazards =
             Release.assert_communication_rollback_hazards!(
               hazards,
               compatible
             )

    clean_hazards = Map.new(hazards, fn {key, _value} -> {key, 0} end)
    legacy = %{target_revision: "sha-legacy", capabilities: MapSet.new()}

    assert ^clean_hazards =
             Release.assert_communication_rollback_hazards!(
               clean_hazards,
               legacy
             )

    assert_raise RuntimeError,
                 ~r/target sha-legacy lacks .*instant_room_lifecycle_v1.*ephemeral_rooms=1/,
                 fn ->
                   Release.assert_communication_rollback_hazards!(
                     %{clean_hazards | ephemeral_rooms: 1},
                     legacy
                   )
                 end

    assert_raise RuntimeError,
                 ~r/instant_room_lifecycle_v1.*ephemeral_join_receipts=1/,
                 fn ->
                   Release.assert_communication_rollback_hazards!(
                     %{clean_hazards | ephemeral_join_receipts: 1},
                     legacy
                   )
                 end

    assert_raise RuntimeError,
                 ~r/instant_room_presence_lease_v1.*ephemeral_presence_leases=1/,
                 fn ->
                   Release.assert_communication_rollback_hazards!(
                     %{clean_hazards | ephemeral_presence_leases: 1},
                     legacy
                   )
                 end

    assert_raise RuntimeError,
                 ~r/instant_room_expiry_worker_v1.*active_ephemeral_room_lifecycle_jobs=1.*active_ephemeral_room_reconciler_jobs=2/,
                 fn ->
                   Release.assert_communication_rollback_hazards!(
                     %{
                       clean_hazards
                       | active_ephemeral_room_lifecycle_jobs: 1,
                         active_ephemeral_room_reconciler_jobs: 2
                     },
                     legacy
                   )
                 end

    assert_raise RuntimeError,
                 ~r/conversation_only_human_v1.*conversation_only_humans=1/,
                 fn ->
                   Release.assert_communication_rollback_hazards!(
                     %{clean_hazards | conversation_only_humans: 1},
                     legacy
                   )
                 end

    guest_capable = %{
      target_revision: "sha-guest-only",
      capabilities: @guest_capabilities |> String.split(",") |> MapSet.new()
    }

    assert ^clean_hazards =
             Release.assert_communication_rollback_hazards!(
               clean_hazards,
               guest_capable
             )
  end
end
