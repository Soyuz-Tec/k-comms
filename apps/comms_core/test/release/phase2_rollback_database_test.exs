defmodule CommsCore.Release.Phase2RollbackDatabaseTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Audit, Release, Repo, RuntimePorts}
  alias CommsCore.Accounts.{MemberWorkspace, User}
  alias CommsCore.Audit.{ResourceHistoryQuery, ResourceHistorySnapshot}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :release

  # This is the actual qualified M1 parent's contract. Retained phase2 state
  # requires its own new capability even when all preceding controls exist.
  @m1_capabilities MapSet.new([
                     "guest_identity_v1",
                     "guest_admission_expiry_worker_v1",
                     "instant_room_lifecycle_v1",
                     "instant_room_presence_lease_v1",
                     "instant_room_expiry_worker_v1",
                     "conversation_only_human_v1",
                     "enterprise_identity_v1",
                     "uc_artifact_lifecycle_v1",
                     "uc_voicemail_lifecycle_v1",
                     "uc_advanced_telephony_v1",
                     "scheduled_meeting_lifecycle_v1",
                     "rich_content_erasure_v1"
                   ])

  test "the actual one-shot commands explain malformed capability refusal before hazard evaluation" do
    names =
      ~w(K_COMMS_RUNTIME_PURPOSE K_COMMS_ROLLBACK_TARGET_REVISION K_COMMS_ROLLBACK_TARGET_CAPABILITIES K_COMMS_ROLLBACK_WRITES_QUIESCED)

    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      System.put_env("K_COMMS_RUNTIME_PURPOSE", "one_shot")
      System.put_env("K_COMMS_ROLLBACK_TARGET_REVISION", "synthetic-invalid-capabilities")

      System.put_env(
        "K_COMMS_ROLLBACK_TARGET_CAPABILITIES",
        "guest_identity_v1,guest_identity_v1"
      )

      System.put_env("K_COMMS_ROLLBACK_WRITES_QUIESCED", "true")

      for command <- [
            &Release.assert_guest_rollback_compatible!/0,
            &Release.assert_communication_rollback_compatible!/0
          ] do
        assert_raise RuntimeError, ~r/compatibility check refused:.*unique known names/, command
      end
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "only active exact-worker true-boolean history purge continuations are rollback hazards" do
    worker = RuntimePorts.job_worker_name!(:audit_history_snapshot_purge)
    other_worker = "CommsWorkers.UnrelatedHistoryRollbackProbe"
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    initial = Repo.active_continuation_oban_job_count!(worker)
    initial_other = Repo.active_continuation_oban_job_count!(other_worker)
    active_states = ~w(available scheduled executing retryable)

    continuations =
      for state <- active_states do
        insert_job(worker, state, %{"continue" => true}, timestamp)
      end

    for state <- active_states,
        args <- [%{}, %{"continue" => false}, %{"continue" => "true"}, %{"continue" => 1}] do
      insert_job(worker, state, args, timestamp)
    end

    for state <- ~w(completed discarded cancelled) do
      insert_job(worker, state, %{"continue" => true}, timestamp)
    end

    insert_job(other_worker, "available", %{"continue" => true}, timestamp)

    assert Repo.active_continuation_oban_job_count!(worker) == initial + 4
    assert Repo.active_continuation_oban_job_count!(other_worker) == initial_other + 1

    hazards = clean_hazards() |> Map.put(:active_history_purge_jobs, initial + 4)

    assert_raise RuntimeError,
                 ~r/governance_history_v1.*active_history_purge_jobs=/,
                 fn -> Release.assert_communication_rollback_hazards!(hazards, m1_target()) end

    capable = with_capability("governance_history_v1")
    assert ^hazards = Release.assert_communication_rollback_hazards!(hazards, capable)

    ids = Enum.map(continuations, & &1.id)
    Repo.update_all(from(job in Oban.Job, where: job.id in ^ids), set: [state: "completed"])
    assert Repo.active_continuation_oban_job_count!(worker) == initial
  end

  test "all persisted private workspace rows remain hazards when their identity becomes unusable" do
    account = Fixtures.account_fixture()
    assert Accounts.rollback_member_workspace_hazard_count() == 0

    # An empty aggregate still retains versioned setup state and requires its
    # owner. Contact content or an active parent must not decide compatibility.
    assert {:ok, empty} =
             Accounts.update_member_onboarding(
               %{version: 0, action: "resume"},
               Fixtures.subject(account)
             )

    assert empty.contacts == [] and empty.groups == []
    assert empty.version == 1
    assert Accounts.rollback_member_workspace_hazard_count() == 1

    for status <- [:suspended, :deleted] do
      Repo.get!(User, account.user.id)
      |> Ecto.Changeset.change(status: status, access_scope: :conversation_only)
      |> Repo.update!()

      assert Accounts.rollback_member_workspace_hazard_count() == 1
    end

    hazards =
      clean_hazards()
      |> Map.put(:member_workspaces, Accounts.rollback_member_workspace_hazard_count())

    assert_raise RuntimeError, ~r/member_workspace_v1.*member_workspaces=1/, fn ->
      Release.assert_communication_rollback_hazards!(hazards, m1_target())
    end

    assert ^hazards =
             Release.assert_communication_rollback_hazards!(
               hazards,
               with_capability("member_workspace_v1")
             )

    Repo.get_by!(MemberWorkspace, tenant_id: account.tenant.id, user_id: account.user.id)
    |> Repo.delete!()

    assert Accounts.rollback_member_workspace_hazard_count() == 0
    clean = clean_hazards()
    assert ^clean = Release.assert_communication_rollback_hazards!(clean, m1_target())
  end

  test "expired retained history snapshots block an M1 target until physical owner purge" do
    account = Fixtures.account_fixture()
    query = history_query(account)
    assert Audit.rollback_history_snapshot_hazard_count() == 0
    assert {:ok, first} = Audit.resource_history_page(query)
    assert {:ok, second} = Audit.resource_history_page(query)
    expire_snapshot(first.snapshot_id)

    assert {:error, :audit_history_snapshot_unavailable} =
             Audit.resource_history_page(%{query | snapshot_id: first.snapshot_id})

    assert Audit.rollback_history_snapshot_hazard_count() == 2
    assert Repo.get!(ResourceHistorySnapshot, first.snapshot_id)

    hazards =
      clean_hazards()
      |> Map.put(:governance_history_snapshots, Audit.rollback_history_snapshot_hazard_count())

    assert_raise RuntimeError,
                 ~r/governance_history_v1.*governance_history_snapshots=2/,
                 fn -> Release.assert_communication_rollback_hazards!(hazards, m1_target()) end

    assert ^hazards =
             Release.assert_communication_rollback_hazards!(
               hazards,
               with_capability("governance_history_v1")
             )

    assert %{deleted_count: 1, has_more: false} =
             Audit.purge_resource_history_snapshots(DateTime.utc_now(), 1)

    refute Repo.get(ResourceHistorySnapshot, first.snapshot_id)
    assert Repo.get!(ResourceHistorySnapshot, second.snapshot_id)
    assert Audit.rollback_history_snapshot_hazard_count() == 1

    expire_snapshot(second.snapshot_id)

    assert %{deleted_count: 1, has_more: false} =
             Audit.purge_resource_history_snapshots(DateTime.utc_now(), 1)

    assert Audit.rollback_history_snapshot_hazard_count() == 0
    clean = clean_hazards()
    assert ^clean = Release.assert_communication_rollback_hazards!(clean, m1_target())
  end

  test "tenant fingerprint includes private workspace and history snapshot identities without leaking them" do
    fixed = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    before = Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug)
    assert before.counts.member_workspaces == 0
    assert before.counts.audit_history_snapshots == 0

    assert {:ok, _} =
             Accounts.update_member_onboarding(
               %{version: 0, action: "dismiss"},
               Fixtures.subject(fixed)
             )

    workspace =
      Repo.get_by!(MemberWorkspace, tenant_id: fixed.tenant.id, user_id: fixed.user.id)

    after_private = Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug)
    assert after_private.counts.member_workspaces == 1
    refute after_private.fingerprint_sha256 == before.fingerprint_sha256

    assert Accounts.release_tenant_fingerprint_fragment(Repo, fixed.tenant.id).member_workspaces ==
             [workspace.id]

    assert {:ok, page} = Audit.resource_history_page(history_query(fixed))
    after_history = Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug)
    assert after_history.counts.member_workspaces == 1
    assert after_history.counts.audit_history_snapshots == 1
    refute after_history.fingerprint_sha256 == after_private.fingerprint_sha256

    assert Audit.release_tenant_fingerprint_fragment(Repo, fixed.tenant.id).audit_history_snapshots ==
             [page.snapshot_id]

    assert {:ok, _} =
             Accounts.update_member_onboarding(
               %{version: 0, action: "dismiss"},
               Fixtures.subject(other)
             )

    assert {:ok, _} = Audit.resource_history_page(history_query(other))
    assert Release.instant_room_tenant_fingerprint(Repo, fixed.tenant.slug) == after_history

    output = Release.format_instant_room_tenant_fingerprint(after_history)
    assert output =~ "member_workspaces=1"
    assert output =~ "audit_history_snapshots=1"

    for identity <- [
          workspace.id,
          page.snapshot_id,
          fixed.tenant.id,
          fixed.user.id,
          fixed.user.email
        ] do
      refute output =~ identity
    end
  end

  defp insert_job(worker, state, args, timestamp) do
    %Oban.Job{}
    |> Ecto.Changeset.change(%{
      state: state,
      queue: "default",
      worker: worker,
      args: Map.put(args, "probe", Ecto.UUID.generate()),
      meta: %{},
      tags: [],
      errors: [],
      attempt: 0,
      max_attempts: 20,
      priority: 0,
      inserted_at: timestamp,
      scheduled_at: timestamp
    })
    |> Repo.insert!()
  end

  defp history_query(account) do
    %ResourceHistoryQuery{
      tenant_id: account.tenant.id,
      resource_type: "deletion_request",
      resource_id: Ecto.UUID.generate(),
      actions: ["deletion_request.create"],
      origin_action: "deletion_request.create",
      limit: 1
    }
  end

  defp expire_snapshot(id) do
    past = DateTime.utc_now() |> DateTime.add(-7_200, :second) |> DateTime.truncate(:microsecond)

    Repo.get!(ResourceHistorySnapshot, id)
    |> Ecto.Changeset.change(observed_at: past, expires_at: DateTime.add(past, 3_600, :second))
    |> Repo.update!()
  end

  defp m1_target,
    do: %{
      target_revision: "e7d85225b875a83d071f10c27a5e3e7f2675540e",
      capabilities: @m1_capabilities
    }

  defp with_capability(capability),
    do: %{m1_target() | capabilities: MapSet.put(@m1_capabilities, capability)}

  defp clean_hazards do
    Map.new(
      [
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
        :calendar_owner_state,
        :active_calendar_jobs,
        :calendar_erasure_state
      ],
      &{&1, 0}
    )
  end
end
