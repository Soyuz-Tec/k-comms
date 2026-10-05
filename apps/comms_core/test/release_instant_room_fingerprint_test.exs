defmodule CommsCore.ReleaseInstantRoomFingerprintTest do
  use CommsCore.DataCase, async: true

  alias CommsCore.Release
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :release

  @categories [
    :users,
    :sessions,
    :devices,
    :conversations,
    :memberships,
    :messages,
    :guest_links,
    :guest_admissions,
    :ephemeral_rooms,
    :ephemeral_presence_leases,
    :ephemeral_join_receipts,
    :audit_events,
    :outbox_events,
    :calls,
    :call_participants,
    :call_artifacts,
    :call_artifact_consents,
    :call_artifact_segments,
    :call_artifact_summaries,
    :member_workspaces,
    :audit_history_snapshots,
    :shared_documents,
    :shared_document_operations,
    :telephony_calls,
    :telephony_ivr_menus,
    :telephony_ivr_runs,
    :telephony_ivr_event_receipts,
    :telephony_agent_states,
    :workspace_domain_claims,
    :calendar_connections,
    :calendar_oauth_challenges,
    :calendar_exports,
    :calendar_event_mappings,
    :calendar_sync_commands,
    :calendar_erasure_receipts,
    :phone_provisioning_commands,
    :native_push_registrations,
    :native_call_wakes,
    :matrix_identities,
    :matrix_client_sessions,
    :private_matrix_rooms,
    :opaque_private_events,
    :federation_trusts,
    :federation_rooms,
    :federation_participants,
    :federation_commands,
    :federation_event_receipts
  ]

  defmodule ReadOnlyRepo do
    def one(%Ecto.Query{}), do: "tenant-internal-id"

    def all(%Ecto.Query{from: %{source: {table, _schema}}}) do
      [
        Map.fetch!(
          %{
            "users" => "user-internal-id",
            "sessions" => "session-internal-id",
            "devices" => "device-internal-id",
            "conversations" => "conversation-internal-id",
            "conversation_memberships" => "membership-internal-id",
            "messages" => "message-internal-id",
            "conversation_guest_links" => "guest-link-internal-id",
            "conversation_guest_admissions" => "guest-admission-internal-id",
            "conversation_ephemeral_rooms" => "room-internal-id",
            "conversation_ephemeral_presence_leases" => "lease-internal-id",
            "conversation_ephemeral_join_receipts" => "receipt-internal-id",
            "audit_events" => "audit-internal-id",
            "outbox_events" => "outbox-internal-id",
            "audio_calls" => "call-internal-id",
            "audio_call_participants" => "participant-internal-id",
            "call_artifacts" => "artifact-internal-id",
            "call_artifact_consents" => "consent-internal-id",
            "call_artifact_segments" => "segment-internal-id",
            "call_artifact_summaries" => "summary-internal-id",
            "member_workspaces" => "private-workspace-internal-id",
            "audit_resource_history_snapshots" => "history-snapshot-internal-id",
            "shared_documents" => "shared-document-internal-id",
            "shared_document_operations" => "shared-document-operation-internal-id",
            "telephony_calls" => "telephone-call-internal-id",
            "telephony_ivr_menus" => "ivr-menu-internal-id",
            "telephony_ivr_runs" => "ivr-run-internal-id",
            "telephony_ivr_event_receipts" => "ivr-receipt-internal-id",
            "telephony_agent_states" => "agent-state-internal-id",
            "workspace_domain_claims" => "domain-claim-internal-id",
            "calendar_connections" => "calendar-connection-internal-id",
            "calendar_oauth_challenges" => "calendar-challenge-internal-id",
            "calendar_exports" => "calendar-export-internal-id",
            "calendar_event_mappings" => "calendar-mapping-internal-id",
            "calendar_sync_commands" => "calendar-command-internal-id",
            "calendar_erasure_receipts" => "calendar-erasure-internal-id",
            "telephony_provisioning_commands" => "phone-receipt-internal-id",
            "native_push_registrations" => "native-registration-internal-id",
            "native_call_wakes" => "native-wake-internal-id",
            "matrix_identities" => "matrix-identity-internal-id",
            "matrix_client_sessions" => "matrix-session-internal-id",
            "private_matrix_rooms" => "private-room-internal-id",
            "opaque_private_events" => "opaque-event-internal-id",
            "federation_trusts" => "federation-trust-internal-id",
            "federation_rooms" => "federation-room-internal-id",
            "federation_participants" => "federation-participant-internal-id",
            "federation_commands" => "federation-command-internal-id",
            "federation_event_receipts" => "federation-event-receipt-internal-id"
          },
          table
        )
      ]
    end
  end

  test "environment requires the one-shot purpose, dedicated confirmation, and fixed slug" do
    environment = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION" =>
        "fixed-instant-room-tenant-fingerprint-v1",
      "INSTANT_ROOM_TENANT_SLUG" => "k-comms-development"
    }

    assert {:ok, %{tenant_slug: "k-comms-development"}} =
             Release.validate_instant_room_fingerprint_environment(&Map.get(environment, &1))

    for {name, value, expected_error} <- [
          {"K_COMMS_RUNTIME_PURPOSE", "application", :one_shot_runtime_required},
          {"K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION", "wrong",
           :instant_room_fingerprint_confirmation_required},
          {"INSTANT_ROOM_TENANT_SLUG", "Qualification Tenant", :instant_room_tenant_slug_invalid},
          {"INSTANT_ROOM_TENANT_SLUG", "", :instant_room_tenant_slug_invalid}
        ] do
      assert {:error, ^expected_error} =
               Release.validate_instant_room_fingerprint_environment(
                 &(environment
                   |> Map.put(name, value)
                   |> Map.get(&1))
               )
    end
  end

  test "read-only graph query covers every required category and redacts identities" do
    assert Release.instant_room_tenant_fingerprint_categories() == @categories

    report =
      Release.instant_room_tenant_fingerprint(
        ReadOnlyRepo,
        "k-comms-development"
      )

    assert report.version == 1
    assert report.tenant_present
    assert Map.keys(report.counts) |> Enum.sort() == Enum.sort(@categories)
    assert Enum.all?(report.counts, fn {_category, count} -> count == 1 end)
    assert report.fingerprint_sha256 =~ ~r/\A[0-9a-f]{64}\z/

    output = Release.format_instant_room_tenant_fingerprint(report)

    assert output =~
             ~r/\AK_COMMS_INSTANT_ROOM_TENANT_FINGERPRINT_V1 tenant_present=true /

    assert output =~ "ephemeral_join_receipts=1"
    assert output =~ "call_participants=1"
    assert output =~ "telephony_ivr_runs=1"
    assert output =~ "telephony_agent_states=1"
    assert output =~ "phone_provisioning_commands=1"
    assert output =~ ~r/ fingerprint_sha256=[0-9a-f]{64}\z/

    for forbidden <- [
          "k-comms-development",
          "tenant-internal-id",
          "user-internal-id",
          "message-internal-id",
          "call-internal-id",
          "phone-receipt-internal-id",
          "federation-trust-internal-id",
          "federation-room-internal-id",
          "federation-participant-internal-id",
          "federation-command-internal-id",
          "federation-event-receipt-internal-id"
        ] do
      refute output =~ forbidden
    end
  end

  test "simultaneous retained IVR cleanup and every Phone command outcome contribute independently" do
    alias CommsCore.Telephony.{
      AgentState,
      Call,
      IvrEventReceipt,
      IvrMenu,
      IvrRun,
      Number,
      ProvisioningCommand
    }

    alias CommsCore.Telephony
    account = Fixtures.account_fixture()
    unrelated = Fixtures.account_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    before_unrelated = Release.instant_room_tenant_fingerprint(Repo, unrelated.tenant.slug)

    suffix =
      System.unique_integer([:positive, :monotonic])
      |> Integer.to_string()
      |> String.pad_leading(9, "0")

    number =
      Repo.insert!(%Number{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        phone_number: "+1415" <> suffix,
        extension: "101",
        inbound_trunk_id: "ST_synthetic_in",
        outbound_trunk_id: "ST_synthetic_out"
      })

    call =
      Repo.insert!(%Call{
        tenant_id: account.tenant.id,
        number_id: number.id,
        user_id: account.user.id,
        direction: :inbound,
        status: :failed,
        from_number: number.phone_number,
        to_number: number.phone_number,
        extension: "101",
        inbound_trunk_id: number.inbound_trunk_id,
        outbound_trunk_id: number.outbound_trunk_id,
        provider_room: "kc_tel_fingerprint_" <> suffix,
        provider_identity: "synthetic_fingerprint_" <> suffix,
        started_at: now,
        expires_at: DateTime.add(now, 60),
        ended_at: now,
        cleanup_completed_at: now,
        end_reason: "synthetic_completed_cleanup"
      })

    menu =
      Repo.insert!(%IvrMenu{
        tenant_id: account.tenant.id,
        number_id: number.id,
        name: "Retained menu",
        prompt_media: "sound:custom/menu",
        choices: %{"1" => %{"kind" => "hangup"}},
        fallback: %{"kind" => "hangup"},
        enabled: false
      })

    run =
      Repo.insert!(%IvrRun{
        tenant_id: account.tenant.id,
        call_id: call.id,
        menu_id: menu.id,
        menu_version: menu.version,
        snapshot: %{"name" => menu.name},
        phase: :completed,
        effect_claim_fingerprint: String.duplicate("a", 64),
        expires_at: DateTime.add(now, 60)
      })

    receipt =
      Repo.insert!(%IvrEventReceipt{
        tenant_id: account.tenant.id,
        run_id: run.id,
        event_id: String.duplicate("b", 64),
        body_fingerprint: String.duplicate("c", 64),
        step: 1,
        event_type: "ChannelDestroyed"
      })

    agent =
      Repo.insert!(%AgentState{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        state: :away,
        expires_at: DateTime.add(now, -60),
        inserted_at: DateTime.add(now, -600),
        updated_at: DateTime.add(now, -600)
      })

    commands =
      for status <- [:inspecting, :verified, :applying, :unknown, :applied, :failed, :reconciling] do
        Repo.insert!(%ProvisioningCommand{
          tenant_id: account.tenant.id,
          actor_user_id: account.user.id,
          actor_device_id: account.device.id,
          actor_session_id: account.session.id,
          request_id: Ecto.UUID.generate(),
          assignment_version: 0,
          desired: %{"phone_number" => number.phone_number},
          status: status,
          lease_expires_at: DateTime.add(now, -60),
          effect_consumed: status in [:unknown, :applied]
        })
      end

    fragment = Telephony.release_tenant_fingerprint_fragment(Repo, account.tenant.id)

    assert MapSet.new(Map.keys(fragment)) ==
             MapSet.new([
               :phone_provisioning_commands,
               :telephony_calls,
               :telephony_ivr_menus,
               :telephony_ivr_runs,
               :telephony_ivr_event_receipts,
               :telephony_agent_states
             ])

    assert fragment.telephony_calls == [call.id]
    assert fragment.telephony_ivr_menus == [menu.id]
    assert fragment.telephony_ivr_runs == [run.id]
    assert fragment.telephony_ivr_event_receipts == [receipt.id]
    assert fragment.telephony_agent_states == [agent.id]

    assert MapSet.new(fragment.phone_provisioning_commands) ==
             MapSet.new(Enum.map(commands, & &1.id))

    report = Release.instant_room_tenant_fingerprint(Repo, account.tenant.slug)
    assert report.counts.phone_provisioning_commands == 7
    assert report.counts.telephony_calls == 1
    assert report.counts.telephony_ivr_menus == 1
    assert report.counts.telephony_ivr_runs == 1
    assert report.counts.telephony_ivr_event_receipts == 1
    assert report.counts.telephony_agent_states == 1

    assert before_unrelated ==
             Release.instant_room_tenant_fingerprint(Repo, unrelated.tenant.slug)

    output = Release.format_instant_room_tenant_fingerprint(report)

    for private <- [
          number.phone_number,
          menu.name,
          run.id,
          receipt.event_id,
          account.tenant.id,
          account.user.id
        ] do
      refute output =~ private
    end

    # Each retained owner contributes to the real digest, even after cleanup.
    Repo.delete!(Enum.find(commands, &(&1.status == :failed)))
    after_phone = Release.instant_room_tenant_fingerprint(Repo, account.tenant.slug)
    assert after_phone.counts.phone_provisioning_commands == 6
    refute after_phone.fingerprint_sha256 == report.fingerprint_sha256
    Repo.delete!(receipt)
    after_ivr = Release.instant_room_tenant_fingerprint(Repo, account.tenant.slug)
    assert after_ivr.counts.telephony_ivr_event_receipts == 0
    refute after_ivr.fingerprint_sha256 == after_phone.fingerprint_sha256
  end

  test "fingerprint is stable, tenant-isolated, and changes with fixed-tenant residue" do
    suffix = System.unique_integer([:positive, :monotonic])

    fixed =
      Fixtures.account_fixture(%{
        tenant_slug: "fixed-fingerprint-#{suffix}"
      })

    other = Fixtures.account_fixture()

    before =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        fixed.tenant.slug
      )

    assert before ==
             Release.instant_room_tenant_fingerprint(
               CommsCore.Repo,
               fixed.tenant.slug
             )

    assert before.tenant_present
    assert before.counts.users == 1
    assert before.counts.sessions == 1
    assert before.counts.devices == 1
    assert before.counts.conversations == 1
    assert before.counts.memberships == 1

    Fixtures.user_fixture(other)

    assert before ==
             Release.instant_room_tenant_fingerprint(
               CommsCore.Repo,
               fixed.tenant.slug
             )

    Fixtures.user_fixture(fixed)

    after_residue =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        fixed.tenant.slug
      )

    assert after_residue.counts.users == before.counts.users + 1
    refute after_residue.fingerprint_sha256 == before.fingerprint_sha256

    output = Release.format_instant_room_tenant_fingerprint(after_residue)

    refute output =~ fixed.tenant.slug
    refute output =~ fixed.tenant.id
    refute output =~ fixed.user.id
    refute output =~ fixed.user.email
  end

  test "an absent configured tenant has deterministic zero counts" do
    first =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        "absent-fixed-instant-room"
      )

    second =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        "another-absent-fixed-instant-room"
      )

    refute first.tenant_present
    assert first.counts == Map.new(@categories, &{&1, 0})
    assert first == second
  end
end
