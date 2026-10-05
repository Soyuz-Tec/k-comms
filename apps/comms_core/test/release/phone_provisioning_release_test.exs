defmodule CommsCore.Release.PhoneProvisioningReleaseTest do
  use CommsCore.DataCase, async: true

  alias CommsCore.{Release, Repo, Telephony}
  alias CommsCore.Telephony.ProvisioningCommand
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :release
  @member14 ~w(guest_identity_v1 guest_admission_expiry_worker_v1 instant_room_lifecycle_v1
               instant_room_presence_lease_v1 instant_room_expiry_worker_v1 conversation_only_human_v1
               enterprise_identity_v1 uc_artifact_lifecycle_v1 uc_voicemail_lifecycle_v1
               uc_advanced_telephony_v1 scheduled_meeting_lifecycle_v1 rich_content_erasure_v1
               member_workspace_v1 governance_history_v1)

  test "all retained states count, including expired unconsumed inspections and failed receipts" do
    account = Fixtures.account_fixture()
    initial = Telephony.rollback_phone_provisioning_hazard_count()

    for status <- ~w(inspecting verified applying unknown applied failed reconciling)a do
      receipt(account, status)
    end

    assert Telephony.rollback_phone_provisioning_hazard_count() == initial + 7
    other = Fixtures.account_fixture()
    receipt(other, :failed)
    assert Telephony.rollback_phone_provisioning_hazard_count() == initial + 8
  end

  test "actual Member14 target refuses any Phone receipt but permits an empty Phone owner" do
    account = Fixtures.account_fixture()
    receipt(account, :failed)
    count = Telephony.rollback_phone_provisioning_hazard_count()
    hazards = clean_hazards() |> Map.put(:retained_phone_provisioning_commands, count)

    previous = %{
      target_revision: "faa001613486376b5a1d3eb1ff2964534b7a2fb2",
      capabilities: MapSet.new(@member14)
    }

    assert_raise RuntimeError,
                 ~r/phone_provider_provisioning_v1.*retained_phone_provisioning_commands=/,
                 fn ->
                   Release.assert_communication_rollback_hazards!(hazards, previous)
                 end

    capable = %{
      previous
      | capabilities: MapSet.put(previous.capabilities, "phone_provider_provisioning_v1")
    }

    assert ^hazards = Release.assert_communication_rollback_hazards!(hazards, capable)
    clean = clean_hazards()
    assert ^clean = Release.assert_communication_rollback_hazards!(clean, previous)
  end

  test "Phone receipt fingerprints are stable, tenant scoped, identity sensitive and redacted" do
    fixed = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    before = Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug)
    command = receipt(fixed, :failed)
    after_receipt = Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug)

    assert after_receipt.counts.phone_provisioning_commands ==
             before.counts.phone_provisioning_commands + 1

    refute after_receipt.fingerprint_sha256 == before.fingerprint_sha256

    assert Telephony.release_tenant_fingerprint_fragment(Repo, fixed.tenant.id).phone_provisioning_commands ==
             [command.id]

    receipt(other, :unknown, true)
    assert after_receipt == Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug)
    output = Release.format_instant_room_tenant_fingerprint(after_receipt)
    assert output =~ "phone_provisioning_commands=1"

    for private <- [
          command.id,
          command.request_id,
          fixed.tenant.id,
          fixed.user.id,
          "+14155550123"
        ] do
      refute output =~ private
    end

    Repo.delete!(command)
    assert before == Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug)
  end

  test "migration down refuses destructive receipt rollback even when management is off" do
    path =
      Path.expand(
        "../../priv/repo/migrations/20261006000700_add_phone_provider_provisioning.exs",
        __DIR__
      )

    [{migration, _bytecode}] = Code.require_file(path)

    assert_raise RuntimeError, ~r/receipts must be retained/, fn ->
      apply(migration, :down, [])
    end
  end

  defp receipt(account, status, consumed \\ false) do
    Repo.insert!(%ProvisioningCommand{
      tenant_id: account.tenant.id,
      actor_user_id: account.user.id,
      actor_device_id: account.device.id,
      actor_session_id: account.session.id,
      request_id: Ecto.UUID.generate(),
      assignment_version: 0,
      desired: %{
        "user_id" => account.user.id,
        "phone_number" => "+14155550123",
        "extension" => "101",
        "inbound_trunk_id" => "ST_in",
        "outbound_trunk_id" => "ST_out"
      },
      status: status,
      effect_consumed: consumed,
      lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
  end

  defp clean_hazards do
    Map.new(
      ~w(guest_users active_guest_expiry_jobs ephemeral_rooms ephemeral_join_receipts
               ephemeral_presence_leases active_ephemeral_room_lifecycle_jobs active_ephemeral_room_reconciler_jobs
               conversation_only_humans enterprise_identities scim_credentials retained_call_artifacts
               active_artifact_jobs voicemail_media active_voicemail_jobs advanced_controls active_control_jobs
               active_routing_jobs scheduled_meetings active_meeting_reminder_jobs rich_messages rich_whiteboards
               member_workspaces governance_history_snapshots active_history_purge_jobs retained_phone_provisioning_commands
               shared_documents ivr_state agent_queue_states active_ivr_jobs workspace_domain_claims
               calendar_owner_state calendar_erasure_state active_calendar_jobs recognition_summary_state active_summary_jobs
               native_push_registrations native_call_wake_intents active_native_call_wake_jobs
               matrix_identities private_matrix_rooms opaque_private_events active_matrix_device_jobs active_private_purge_jobs
               federation_state active_federation_jobs)a,
      &{&1, 0}
    )
  end
end
