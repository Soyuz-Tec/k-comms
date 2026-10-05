defmodule CommsWorkers.WorkspaceDomainErasureTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Governance, Repo}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Administration.WorkspaceDomainClaim
  alias CommsCore.Governance.DeletionRequest
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  defmodule Resolver do
    @behaviour CommsCore.Administration.DomainTXTResolver
    @impl true
    def lookup(_query),
      do: {:ok, [Application.fetch_env!(:comms_core, :domain_erasure_test_txt)]}
  end

  setup do
    previous = Application.get_env(:comms_core, :workspace_domain_txt_resolver)
    Application.put_env(:comms_core, :workspace_domain_txt_resolver, Resolver)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :workspace_domain_txt_resolver, previous),
        else: Application.delete_env(:comms_core, :workspace_domain_txt_resolver)

      Application.delete_env(:comms_core, :domain_erasure_test_txt)
    end)

    :ok
  end

  test "registered deletion worker erases personal proof while retaining the current tenant lease" do
    owner = Fixtures.account_fixture()
    approver = Fixtures.step_up(owner)
    target = Fixtures.user_fixture(owner, %{role: :admin}).user
    target_subject = authenticated_subject(owner, target)
    foreign = Fixtures.account_fixture()

    pending = create(target_subject)
    expired = verified_renewal(target_subject)
    timestamp = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.get!(WorkspaceDomainClaim, expired.id)
    |> Ecto.Changeset.change(
      verified_at: DateTime.add(timestamp, -60, :second),
      proof_expires_at: timestamp
    )
    |> Repo.update!()

    current = verified_renewal(target_subject)
    consumed = verified(target_subject)
    consumed_before = Repo.get!(WorkspaceDomainClaim, consumed.id)
    unrelated = create(approver)
    unrelated_before = Repo.get!(WorkspaceDomainClaim, unrelated.id)
    foreign_claim = create(Fixtures.step_up(foreign))
    foreign_before = Repo.get!(WorkspaceDomainClaim, foreign_claim.id)

    approved = approve(owner, target.id, approver)

    assert :ok =
             CommsWorkers.DeletionWorker.perform(%Oban.Job{
               args: %{"deletion_request_id" => approved.id}
             })

    assert Repo.get!(User, target.id).status == :deleted
    assert Repo.get!(Session, target_subject.session_id).revoked_at
    refute Repo.get(WorkspaceDomainClaim, pending.id)
    refute Repo.get(WorkspaceDomainClaim, expired.id)

    retained = Repo.get!(WorkspaceDomainClaim, current.id)
    assert retained.status == :verified
    assert retained.discovery_enabled
    assert retained.version == current.version + 1
    assert is_nil(retained.challenge_actor_user_id)
    assert is_nil(retained.challenge_token)
    assert retained.verified_at == current.verified_at
    assert retained.proof_expires_at == current.proof_expires_at
    assert Administration.discover_workspace_domain(current.domain).available
    assert Repo.get!(WorkspaceDomainClaim, consumed.id) == consumed_before
    assert Repo.get!(WorkspaceDomainClaim, unrelated.id) == unrelated_before
    assert Repo.get!(WorkspaceDomainClaim, foreign_claim.id) == foreign_before

    completed = Repo.get!(DeletionRequest, approved.id)
    assert completed.status == :completed
    assert completed.evidence["domain_challenge_erasure_version"] == 1
    assert completed.evidence["domain_challenges_removed"] == 2
    assert completed.evidence["domain_verified_leases_detached"] == 1

    encoded_evidence = Jason.encode!(completed.evidence)

    for private_value <- [pending.domain, current.domain, current.challenge_value, target.email] do
      refute encoded_evidence =~ private_value
    end

    assert {:error, :forbidden} = Administration.list_workspace_domains(target_subject)
  end

  test "historical user completion missing only domain proof is repaired once under the actual reconciler" do
    owner = Fixtures.account_fixture()
    approver = Fixtures.step_up(owner)
    target = Fixtures.user_fixture(owner, %{role: :admin}).user
    target_subject = authenticated_subject(owner, target)
    legacy = create(target_subject)
    legacy_row = Repo.get!(WorkspaceDomainClaim, legacy.id)
    approved = approve(owner, target.id, approver)

    assert :ok =
             CommsWorkers.DeletionWorker.perform(%Oban.Job{
               args: %{"deletion_request_id" => approved.id}
             })

    # Reproduce a historical completion from before the owner hook, while all
    # older completion proofs are current. The retained User still satisfies FK.
    %WorkspaceDomainClaim{}
    |> WorkspaceDomainClaim.changeset(
      legacy_row
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id])
    )
    |> Repo.insert!()

    completed = Repo.get!(DeletionRequest, approved.id)

    completed
    |> Ecto.Changeset.change(
      evidence:
        Map.drop(completed.evidence, [
          "domain_challenge_erasure_version",
          "domain_challenges_removed",
          "domain_verified_leases_detached"
        ])
    )
    |> Repo.update!()

    assert :ok = CommsWorkers.ErasureReconcilerWorker.perform(%Oban.Job{args: %{}})

    refute Repo.exists?(
             from(c in WorkspaceDomainClaim, where: c.challenge_actor_user_id == ^target.id)
           )

    repaired = Repo.get!(DeletionRequest, approved.id)
    assert repaired.status == :completed
    assert repaired.evidence["domain_challenge_erasure_version"] == 1
    assert repaired.evidence["domain_challenges_removed"] == 1
    assert repaired.evidence["domain_verified_leases_detached"] == 0

    assert {:ok, %{repaired: 0, has_more: false}} =
             Governance.reconcile_completed_erasure(CommsWorkers.ErasureReconcilerWorker, 100)

    assert Repo.get!(DeletionRequest, approved.id) == repaired
  end

  test "domain proof is scoped to user erasure and does not reselect current conversation completion" do
    owner = Fixtures.account_fixture()
    approver = Fixtures.step_up(owner)
    claim = create(approver)
    before = Repo.get!(WorkspaceDomainClaim, claim.id)

    assert {:ok, result} =
             Governance.create_deletion_request(
               %{
                 target_type: "conversation",
                 conversation_id: owner.conversation.id,
                 reason: "Verified conversation erasure scope"
               },
               approver
             )

    assert {:ok, approved} =
             Governance.transition_deletion_request(
               result.request.id,
               %{
                 version: result.request.lock_version,
                 status: "approved",
                 transition_reason: "Conversation scope approved"
               },
               approver
             )

    assert :ok =
             CommsWorkers.DeletionWorker.perform(%Oban.Job{
               args: %{"deletion_request_id" => approved.id}
             })

    completed = Repo.get!(DeletionRequest, approved.id)
    refute Map.has_key?(completed.evidence, "domain_challenge_erasure_version")

    assert {:ok, %{repaired: 0, has_more: false}} =
             Governance.reconcile_completed_erasure(CommsWorkers.ErasureReconcilerWorker, 100)

    assert Repo.get!(WorkspaceDomainClaim, claim.id) == before
  end

  defp create(subject) do
    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, claim} =
      Administration.create_workspace_domain(
        %{domain: "erasure-#{suffix}.example.org", version: 0, discovery_enabled: true},
        subject
      )

    claim
  end

  defp verified(subject) do
    claim = create(subject)
    Application.put_env(:comms_core, :domain_erasure_test_txt, claim.challenge_value)
    {:ok, verified} = Administration.verify_workspace_domain(claim.id, %{version: 1}, subject)
    verified
  end

  defp verified_renewal(subject) do
    claim = verified(subject)

    {:ok, renewed} =
      Administration.renew_workspace_domain(claim.id, %{version: claim.version}, subject)

    renewed
  end

  defp approve(_owner, target_id, subject) do
    {:ok, result} =
      Governance.create_deletion_request(
        %{
          target_type: "user",
          subject_user_id: target_id,
          reason: "Verified domain actor erasure"
        },
        subject
      )

    {:ok, approved} =
      Governance.transition_deletion_request(
        result.request.id,
        %{
          version: result.request.lock_version,
          status: "approved",
          transition_reason: "Identity scope approved"
        },
        subject
      )

    approved
  end

  defp authenticated_subject(owner, user) do
    suffix = user.email |> String.split(["member-", "@"], trim: true) |> hd()
    password = "correct-horse-battery-#{suffix}"

    {:ok, login} =
      Accounts.authenticate_view(owner.tenant.slug, user.email, password, %{
        name: "Domain challenge browser",
        platform: "test"
      })

    subject =
      Fixtures.subject(owner, %{
        user_id: user.id,
        role: user.role,
        session_id: login.session_id,
        device_id: login.device.id
      })

    {:ok, _proof} = Accounts.step_up(%{current_password: password}, subject)
    subject
  end
end
