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
                                  "governance_history_v1",
                                  "shared_documents_v1",
                                  "ivr_routing_v1",
                                  "workspace_domain_discovery_v1",
                                  "calendar_sync_v1",
                                  "calendar_erasure_v1",
                                  "phone_provider_provisioning_v1",
                                  "uc_recognition_summaries_v1",
                                  "native_call_wake_v1",
                                  "private_rooms_v1",
                                  "workspace_federation_v1"
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

  test "six, twelve and fourteen capability receipts require native owner state support" do
    names = String.split(@communication_capabilities, ",")
    # Reuse the actual complete current hazard vocabulary, independently of
    # unrelated owners' clean-state assumptions.
    keys = [
      :guest_users,
      :active_guest_expiry_jobs,
      :ephemeral_rooms,
      :ephemeral_join_receipts,
      :ephemeral_presence_leases,
      :active_ephemeral_room_lifecycle_jobs,
      :active_ephemeral_room_reconciler_jobs,
      :conversation_only_humans,
      :enterprise_identities,
      :scim_credentials,
      :retained_call_artifacts,
      :active_artifact_jobs,
      :voicemail_media,
      :active_voicemail_jobs,
      :advanced_controls,
      :active_control_jobs,
      :active_routing_jobs,
      :scheduled_meetings,
      :active_meeting_reminder_jobs,
      :rich_messages,
      :rich_whiteboards,
      :member_workspaces,
      :governance_history_snapshots,
      :active_history_purge_jobs,
      :native_push_registrations,
      :native_call_wake_intents,
      :active_native_call_wake_jobs,
      :shared_documents,
      :ivr_state,
      :agent_queue_states,
      :active_ivr_jobs,
      :workspace_domain_claims,
      :calendar_owner_state,
      :calendar_erasure_state,
      :active_calendar_jobs,
      :retained_phone_provisioning_commands,
      :recognition_summary_state,
      :active_summary_jobs,
      :matrix_identities,
      :private_matrix_rooms,
      :opaque_private_events,
      :active_matrix_device_jobs,
      :active_private_purge_jobs
    ]

    clean = Map.new(keys, &{&1, 0})

    for count <- [6, 12, 14, 15, length(names)] do
      target = %{
        target_revision: "synthetic-receipt-#{count}",
        capabilities: names |> Enum.take(count) |> MapSet.new()
      }

      assert ^clean = Release.assert_communication_rollback_hazards!(clean, target)

      for key <- [
            :native_push_registrations,
            :native_call_wake_intents,
            :active_native_call_wake_jobs
          ] do
        retained = Map.put(clean, key, 1)

        if count == length(names) do
          assert ^retained = Release.assert_communication_rollback_hazards!(retained, target)
        else
          assert_raise RuntimeError, ~r/lacks native_call_wake_v1.*#{key}=1/, fn ->
            Release.assert_communication_rollback_hazards!(retained, target)
          end
        end
      end
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
      calendar_owner_state: 1,
      calendar_erasure_state: 1,
      active_calendar_jobs: 1,
      governance_history_snapshots: 1,
      active_history_purge_jobs: 1,
      shared_documents: 1,
      ivr_state: 1,
      agent_queue_states: 1,
      active_ivr_jobs: 1,
      workspace_domain_claims: 1,
      retained_phone_provisioning_commands: 1,
      recognition_summary_state: 1,
      active_summary_jobs: 1,
      native_push_registrations: 1,
      native_call_wake_intents: 1,
      active_native_call_wake_jobs: 1,
      matrix_identities: 1,
      private_matrix_rooms: 1,
      opaque_private_events: 1,
      active_matrix_device_jobs: 1,
      active_private_purge_jobs: 1,
      federation_state: 1,
      active_federation_jobs: 1
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
          {"governance_history_v1", [:governance_history_snapshots, :active_history_purge_jobs]},
          {"shared_documents_v1", [:shared_documents]},
          {"ivr_routing_v1", [:ivr_state, :agent_queue_states, :active_ivr_jobs]},
          {"workspace_domain_discovery_v1", [:workspace_domain_claims]},
          {"calendar_sync_v1", [:calendar_owner_state, :active_calendar_jobs]},
          {"calendar_erasure_v1", [:calendar_erasure_state]},
          {"phone_provider_provisioning_v1", [:retained_phone_provisioning_commands]},
          {"uc_recognition_summaries_v1", [:recognition_summary_state, :active_summary_jobs]},
          {"native_call_wake_v1",
           [:native_push_registrations, :native_call_wake_intents, :active_native_call_wake_jobs]},
          {"workspace_federation_v1", [:federation_state, :active_federation_jobs]}
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

    # The actual Member/History source parent has fourteen capabilities.
    # Even a completed IVR run or expired explicit agent row needs its owner.
    member_history = %{
      target_revision: "610b6a",
      capabilities: MapSet.delete(compatible.capabilities, "ivr_routing_v1")
    }

    assert ^clean_hazards =
             Release.assert_communication_rollback_hazards!(clean_hazards, member_history)

    for key <- [:ivr_state, :agent_queue_states, :active_ivr_jobs] do
      retained = Map.put(clean_hazards, key, 1)

      assert_raise RuntimeError, ~r/target 610b6a lacks ivr_routing_v1.*#{key}=1/, fn ->
        Release.assert_communication_rollback_hazards!(retained, member_history)
      end
    end

    for invalid <- [
          Map.delete(clean_hazards, :ivr_state),
          Map.put(clean_hazards, :active_ivr_jobs, -1),
          Map.delete(clean_hazards, :workspace_domain_claims),
          Map.put(clean_hazards, :workspace_domain_claims, -1),
          Map.put(clean_hazards, :workspace_domain_claims, "0"),
          Map.delete(clean_hazards, :retained_phone_provisioning_commands),
          Map.put(clean_hazards, :retained_phone_provisioning_commands, -1),
          Map.delete(clean_hazards, :native_push_registrations),
          Map.put(clean_hazards, :active_native_call_wake_jobs, -1),
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
