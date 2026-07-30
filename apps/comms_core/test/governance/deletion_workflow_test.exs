defmodule CommsCore.Governance.DeletionWorkflowTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.User
  alias CommsCore.Conversations.Membership
  alias CommsCore.Governance
  alias CommsCore.Governance.{DeletionExecution, DeletionRequest}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "legal holds block deletion completion until released" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    deletion_target = Fixtures.user_fixture(account)

    assert {:ok, deletion_conversation} =
             CommsCore.Conversations.create(
               %{
                 title: "Erasure boundary proof",
                 kind: "group",
                 member_ids: [deletion_target.user.id]
               },
               subject
             )

    assert {:ok, hold_result} =
             Governance.create_legal_hold(
               %{
                 name: "Investigation hold",
                 reason: "Preserve evidence for an active investigation",
                 scope_type: "user",
                 subject_user_id: deletion_target.user.id,
                 idempotency_key: "hold-001"
               },
               subject
             )

    assert {:ok, request_result} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: deletion_target.user.id,
                 reason: "Verified account deletion request",
                 idempotency_key: "delete-001"
               },
               subject
             )

    request = request_result.request

    assert {:ok, _approved} =
             Governance.transition_deletion_request(
               request.id,
               %{version: 1, status: "approved", transition_reason: "Deletion request verified"},
               subject
             )

    assert {:error, :legal_hold_active} =
             Governance.claim_deletion_request(
               request.id,
               :"Elixir.CommsWorkers.DeletionWorker"
             )

    assert {:ok, released} =
             Governance.release_legal_hold(
               hold_result.hold.id,
               %{version: hold_result.hold.lock_version, release_reason: "Investigation closed"},
               subject
             )

    assert released.status == :released

    assert {:ok, claim} =
             Governance.claim_deletion_request(
               request.id,
               :"Elixir.CommsWorkers.DeletionWorker"
             )

    assert %DeletionExecution{} = claim
    refute inspect(claim) =~ "objects"
    assert Repo.get!(DeletionRequest, request.id).status == :in_progress

    assert {:error, :invalid_status} =
             Governance.transition_deletion_request(
               request.id,
               %{
                 version: claim.expected_version,
                 status: "completed",
                 transition_reason: "Client must not certify completion"
               },
               subject
             )

    assert {:ok, completion} =
             Governance.complete_deletion_request(
               request.id,
               claim.expected_version,
               %{deleted_object_count: 0},
               :"Elixir.CommsWorkers.DeletionWorker"
             )

    assert completion.request.status == :completed

    assert (completion.request.evidence[:executor] || completion.request.evidence["executor"]) ==
             "CommsWorkers.DeletionWorker"

    erased_user = Repo.get!(User, deletion_target.user.id)
    assert erased_user.status == :deleted
    assert erased_user.display_name == "Deleted user"

    erased_membership =
      Repo.get_by!(Membership,
        tenant_id: account.tenant.id,
        conversation_id: deletion_conversation.id,
        user_id: deletion_target.user.id
      )

    assert erased_membership.left_at
  end
end
