defmodule CommsCore.Governance.AuthorizationTest do
  use CommsCore.DataCase, async: false

  import CommsCore.TrustGovernanceTestSupport

  alias CommsCore.{Audit, Governance, RuntimePorts}
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "governance owns its role, step-up, and denial policies" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    moderator = Fixtures.user_fixture(account, %{role: :moderator})
    compliance = Fixtures.user_fixture(account, %{role: :compliance_admin})

    owner_subject = Fixtures.subject(account)
    member_subject = authenticated_subject(account, member.user, "member-policy-browser")
    moderator_subject = authenticated_subject(account, moderator.user, "moderator-policy-browser")

    compliance_subject =
      authenticated_subject(account, compliance.user, "compliance-policy-browser")

    assert {:error, :forbidden} = Governance.authorize_governance(member_subject)
    assert {:error, :forbidden} = Governance.authorize_governance(moderator_subject)
    assert {:error, :step_up_required} = Governance.authorize_governance(compliance_subject)
    assert {:error, :step_up_required} = Governance.authorize_governance(owner_subject)

    denied_permissions =
      Audit.list(%{
        tenant_id: account.tenant.id,
        action: "authorization.denied",
        limit: 20
      })
      |> Enum.map(& &1.metadata["permission"])
      |> MapSet.new()

    assert MapSet.member?(denied_permissions, "govern_tenant")

    stepped_up_owner = Fixtures.step_up(account, owner_subject)
    assert :ok = Governance.authorize_governance(stepped_up_owner)
    assert {:ok, []} = Governance.list_legal_holds(%{}, stepped_up_owner)
  end

  test "governance targets cannot cross tenants" do
    account = Fixtures.account_fixture()
    other = Fixtures.account_fixture()

    assert {:error, :invalid_governance_target} =
             Governance.create_legal_hold(
               %{
                 name: "Invalid hold",
                 reason: "Attempted cross-tenant target",
                 scope_type: "user",
                 subject_user_id: other.user.id
               },
               Fixtures.step_up(account)
             )
  end

  test "unauthorized worker identities cannot mutate deletion or retention state" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    target = Fixtures.user_fixture(account)

    assert {:ok, request_result} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: target.user.id,
                 reason: "Verify worker authorization boundary"
               },
               subject
             )

    assert {:ok, approved} =
             Governance.transition_deletion_request(
               request_result.request.id,
               %{
                 version: request_result.request.lock_version,
                 status: "approved",
                 transition_reason: "Request is ready for the authorized worker"
               },
               subject
             )

    audit_count = tenant_audit_count(account.tenant.id)
    job_count = Repo.aggregate(Oban.Job, :count)

    assert {:error, :forbidden} =
             Governance.claim_deletion_request(approved.id, __MODULE__)

    persisted_approved = Repo.get!(DeletionRequest, approved.id)
    assert persisted_approved.status == :approved
    assert persisted_approved.lock_version == approved.lock_version
    assert persisted_approved.execution_attempts == approved.execution_attempts
    assert tenant_audit_count(account.tenant.id) == audit_count
    assert Repo.aggregate(Oban.Job, :count) == job_count

    assert {:ok, claim} =
             Governance.claim_deletion_request(
               approved.id,
               RuntimePorts.job_worker!(:deletion)
             )

    audit_count = tenant_audit_count(account.tenant.id)
    job_count = Repo.aggregate(Oban.Job, :count)

    assert {:error, :forbidden} =
             Governance.complete_deletion_request(
               approved.id,
               claim.expected_version,
               %{deleted_object_count: 0},
               __MODULE__
             )

    assert {:error, :forbidden} =
             Governance.record_deletion_failure(
               approved.id,
               :unauthorized_failure,
               __MODULE__
             )

    assert {:error, :forbidden} =
             Governance.enqueue_due_retention(account.tenant.id, __MODULE__)

    persisted_claim = Repo.get!(DeletionRequest, approved.id)
    assert persisted_claim.status == :in_progress
    assert persisted_claim.lock_version == claim.expected_version
    assert persisted_claim.execution_attempts > approved.execution_attempts
    assert is_nil(persisted_claim.execution_error)
    assert is_nil(persisted_claim.completed_at)
    assert persisted_claim.evidence == %{}
    assert Repo.get!(CommsCore.Accounts.User, target.user.id).status == :active
    assert tenant_audit_count(account.tenant.id) == audit_count
    assert Repo.aggregate(Oban.Job, :count) == job_count
  end
end
