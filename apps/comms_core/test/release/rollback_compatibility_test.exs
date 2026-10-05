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
                                  "conversation_only_human_v1",
                                  "enterprise_identity_v1",
                                  "uc_artifact_lifecycle_v1",
                                  "uc_voicemail_lifecycle_v1",
                                  "uc_advanced_telephony_v1",
                                  "scheduled_meeting_lifecycle_v1",
                                  "rich_content_erasure_v1",
                                  "member_workspace_v1",
                                  "governance_history_v1"
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
      conversation_only_humans: 8,
      enterprise_identities: 1,
      scim_credentials: 1,
      retained_call_artifacts: 1,
      active_artifact_jobs: 1,
      voicemail_media: 1,
      active_voicemail_jobs: 1,
      advanced_controls: 1,
      active_control_jobs: 1,
      active_routing_jobs: 1,
      scheduled_meetings: 1,
      active_meeting_reminder_jobs: 1,
      rich_messages: 1,
      rich_whiteboards: 1,
      member_workspaces: 1,
      governance_history_snapshots: 1,
      active_history_purge_jobs: 1
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

    # The actual preceding release declares every old capability. None of its
    # guest/instant-room support proves it can enforce these new controls.
    previous_release = %{
      target_revision: "23896227",
      capabilities:
        @communication_capabilities
        |> String.split(",")
        |> Enum.take(6)
        |> MapSet.new()
    }

    assert ^clean_hazards =
             Release.assert_communication_rollback_hazards!(clean_hazards, previous_release)

    for {capability, keys} <- [
          {"enterprise_identity_v1", [:enterprise_identities, :scim_credentials]},
          {"uc_artifact_lifecycle_v1", [:retained_call_artifacts, :active_artifact_jobs]},
          {"uc_voicemail_lifecycle_v1", [:voicemail_media, :active_voicemail_jobs]},
          {"uc_advanced_telephony_v1",
           [:advanced_controls, :active_control_jobs, :active_routing_jobs]},
          {"scheduled_meeting_lifecycle_v1",
           [:scheduled_meetings, :active_meeting_reminder_jobs]},
          {"rich_content_erasure_v1", [:rich_messages, :rich_whiteboards]},
          {"member_workspace_v1", [:member_workspaces]},
          {"governance_history_v1", [:governance_history_snapshots, :active_history_purge_jobs]}
        ],
        key <- keys do
      state = Map.put(clean_hazards, key, 1)

      assert_raise RuntimeError, ~r/target 23896227 lacks #{capability}.*#{key}=1/, fn ->
        Release.assert_communication_rollback_hazards!(state, previous_release)
      end

      # Each capability authorizes only its own state; no unrelated new
      # capability is required when the remaining owner projections are zero.
      capable = %{
        previous_release
        | capabilities: MapSet.put(previous_release.capabilities, capability)
      }

      assert ^state = Release.assert_communication_rollback_hazards!(state, capable)
    end

    for invalid <- [
          Map.delete(clean_hazards, :member_workspaces),
          Map.delete(clean_hazards, :governance_history_snapshots),
          Map.put(clean_hazards, :active_history_purge_jobs, -1),
          Map.delete(clean_hazards, :enterprise_identities),
          Map.put(clean_hazards, :voicemail_media, nil),
          Map.put(clean_hazards, :rich_whiteboards, -1),
          Map.put(clean_hazards, :retained_call_artifacts, "0")
        ] do
      assert_raise RuntimeError, ~r/invalid hazard snapshot/, fn ->
        Release.assert_communication_rollback_hazards!(invalid, compatible)
      end
    end
  end
end
