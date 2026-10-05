defmodule CommsCore.Release.WorkspaceDomainRollbackDatabaseTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query

  alias CommsCore.{Administration, Release, Repo}
  alias CommsCore.Administration.{Tenant, WorkspaceDomainClaim}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :release
  @phase2_capabilities ~w(guest_identity_v1 guest_admission_expiry_worker_v1
    instant_room_lifecycle_v1 instant_room_presence_lease_v1 instant_room_expiry_worker_v1
    conversation_only_human_v1 enterprise_identity_v1 uc_artifact_lifecycle_v1
    uc_voicemail_lifecycle_v1 uc_advanced_telephony_v1 scheduled_meeting_lifecycle_v1
    rich_content_erasure_v1 member_workspace_v1 governance_history_v1)

  test "every retained claim blocks the actual Member/History target until physical owner revocation" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.step_up(owner)
    assert Administration.retained_workspace_domain_claim_count(Repo) == 0

    {:ok, pending} = create(subject, false)
    {:ok, verified} = create(subject, true)
    {:ok, expired} = create(subject, false)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.get!(WorkspaceDomainClaim, verified.id)
    |> Ecto.Changeset.change(
      status: :verified,
      verified_at: timestamp,
      proof_expires_at: DateTime.add(timestamp, 60, :second),
      challenge_token: nil,
      challenge_actor_user_id: nil
    )
    |> Repo.update!()

    Repo.get!(WorkspaceDomainClaim, expired.id)
    |> Ecto.Changeset.change(
      status: :expired,
      challenge_expires_at: DateTime.add(timestamp, -60, :second)
    )
    |> Repo.update!()

    assert Administration.retained_workspace_domain_claim_count(Repo) == 3

    Repo.get!(Tenant, owner.tenant.id)
    |> Ecto.Changeset.change(status: :suspended)
    |> Repo.update!()

    assert Administration.retained_workspace_domain_claim_count(Repo) == 3
    refute Administration.discover_workspace_domain(verified.domain).available

    hazards = clean_hazards() |> Map.put(:workspace_domain_claims, 3)

    target = %{
      target_revision: "2d1224bc367c6ba1b7a9f29d447e224e8f76dc5f",
      capabilities: MapSet.new(@phase2_capabilities)
    }

    assert_raise RuntimeError, ~r/workspace_domain_discovery_v1.*workspace_domain_claims=3/, fn ->
      Release.assert_communication_rollback_hazards!(hazards, target)
    end

    compatible = %{
      target
      | capabilities: MapSet.put(target.capabilities, "workspace_domain_discovery_v1")
    }

    assert ^hazards = Release.assert_communication_rollback_hazards!(hazards, compatible)
    assert map_size(hazards) == 25

    for invalid <- [
          Map.delete(hazards, :workspace_domain_claims),
          Map.put(hazards, :workspace_domain_claims, nil),
          Map.put(hazards, :workspace_domain_claims, "3"),
          Map.put(hazards, :workspace_domain_claims, -1)
        ] do
      assert_raise RuntimeError, ~r/invalid hazard snapshot/, fn ->
        Release.assert_communication_rollback_hazards!(invalid, compatible)
      end
    end

    Repo.get!(Tenant, owner.tenant.id) |> Ecto.Changeset.change(status: :active) |> Repo.update!()

    for claim <- [pending, verified, expired] do
      assert {:ok, _} = Administration.revoke_workspace_domain(claim.id, %{version: 1}, subject)
    end

    assert Administration.retained_workspace_domain_claim_count(Repo) == 0
    clean = clean_hazards()
    assert ^clean = Release.assert_communication_rollback_hazards!(clean, target)
  end

  test "owner domain IDs contribute to the selected tenant hash without leaking domains or tokens" do
    owner = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    before = Release.instant_room_tenant_fingerprint(Repo, owner.tenant.slug)
    assert before.counts.workspace_domain_claims == 0
    {:ok, claim} = create(Fixtures.step_up(owner), false)
    captured = Release.instant_room_tenant_fingerprint(Repo, owner.tenant.slug)
    assert captured.counts.workspace_domain_claims == 1
    refute captured.fingerprint_sha256 == before.fingerprint_sha256

    assert Administration.workspace_domain_release_fingerprint_fragment(Repo, owner.tenant.id) ==
             %{workspace_domain_claims: [claim.id]}

    {:ok, _foreign} = create(Fixtures.step_up(other), true)
    assert Release.instant_room_tenant_fingerprint(Repo, owner.tenant.slug) == captured
    output = Release.format_instant_room_tenant_fingerprint(captured)
    assert output =~ "workspace_domain_claims=1"

    for private_value <- [claim.id, claim.domain, claim.challenge_value, owner.user.email] do
      refute output =~ private_value
    end

    # A retained expired row still contributes its identity to the same hash.
    Repo.update_all(from(c in WorkspaceDomainClaim, where: c.id == ^claim.id),
      set: [status: :expired]
    )

    assert Release.instant_room_tenant_fingerprint(Repo, owner.tenant.slug) == captured
  end

  defp create(subject, enabled) do
    suffix = System.unique_integer([:positive, :monotonic])

    Administration.create_workspace_domain(
      %{domain: "rollback-#{suffix}.example.org", version: 0, discovery_enabled: enabled},
      subject
    )
  end

  defp clean_hazards do
    Map.new(
      ~w(guest_users active_guest_expiry_jobs ephemeral_rooms ephemeral_join_receipts
      ephemeral_presence_leases active_ephemeral_room_lifecycle_jobs active_ephemeral_room_reconciler_jobs
      conversation_only_humans enterprise_identities scim_credentials retained_call_artifacts active_artifact_jobs
      voicemail_media active_voicemail_jobs advanced_controls active_control_jobs active_routing_jobs
      scheduled_meetings active_meeting_reminder_jobs rich_messages rich_whiteboards member_workspaces
      governance_history_snapshots active_history_purge_jobs workspace_domain_claims)a,
      &{&1, 0}
    )
  end
end
