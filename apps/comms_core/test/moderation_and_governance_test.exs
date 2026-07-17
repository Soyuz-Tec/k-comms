defmodule CommsCore.ModerationAndGovernanceTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Audit, Governance, Messaging, Moderation, RuntimePorts}
  alias CommsCore.Accounts.User
  alias CommsCore.Conversations.Membership
  alias CommsCore.Governance.{DeletionExecution, DeletionRequest}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "members report idempotently and moderators resolve with version checks" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    owner_subject = Fixtures.step_up(account)

    assert {:ok, conversation} =
             CommsCore.Conversations.create(
               %{
                 title: "Safety",
                 kind: "group",
                 member_ids: [member.user.id]
               },
               owner_subject
             )

    member_subject = authenticated_subject(account, member.user, "member-browser")

    attrs = %{
      conversation_id: conversation.id,
      subject_user_id: account.user.id,
      category: "harassment",
      summary: "Repeated unwanted messages",
      details: "Reported through the in-product safety workflow",
      idempotency_key: "report-001"
    }

    assert {:ok, first} = Moderation.create_case(attrs, member_subject)
    assert first.replayed == false
    assert {:ok, replay} = Moderation.create_case(attrs, member_subject)
    assert replay.replayed == true
    assert replay.case.id == first.case.id

    assert {:error, :forbidden} = Moderation.list_cases(%{}, member_subject)
    assert {:ok, [_]} = Moderation.list_cases(%{status: "open"}, owner_subject)

    assert {:ok, result} =
             Moderation.add_action(
               first.case.id,
               %{version: 1, action_type: "resolve", note: "Reviewed and resolved"},
               owner_subject
             )

    assert result.case.status == :resolved
    assert result.case.lock_version == 2
    assert result.action.action_type == :resolve

    assert {:error, :stale_version} =
             Moderation.add_action(
               first.case.id,
               %{version: 1, action_type: "reopen"},
               owner_subject
             )
  end

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

    assert {:ok, policy_result} =
             Governance.create_retention_policy(
               %{
                 name: "Default retention",
                 scope_type: "tenant",
                 retention_days: 365,
                 delete_attachments: false,
                 idempotency_key: "retention-001"
               },
               subject
             )

    assert policy_result.policy.retention_days == 365
    assert policy_result.policy.delete_attachments == false

    assert {:ok, policy_replay} =
             Governance.create_retention_policy(
               %{
                 name: "Default retention",
                 scope_type: "tenant",
                 retention_days: 365,
                 delete_attachments: false,
                 idempotency_key: "retention-001"
               },
               subject
             )

    assert policy_replay.replayed

    assert {:error, :reason_required} =
             Governance.update_retention_policy(
               policy_result.policy.id,
               %{version: policy_result.policy.lock_version, status: "disabled"},
               subject
             )

    assert {:ok, disabled_policy} =
             Governance.update_retention_policy(
               policy_result.policy.id,
               %{
                 version: policy_result.policy.lock_version,
                 status: "disabled",
                 reason: "Workspace retention policy paused for review"
               },
               subject
             )

    assert disabled_policy.status == :disabled

    retention_audit =
      Audit.get_by!(%{
        tenant_id: account.tenant.id,
        action: "retention_policy.update",
        resource_id: disabled_policy.id
      })

    assert (retention_audit.metadata["reason"] || retention_audit.metadata[:reason]) ==
             "Workspace retention policy paused for review"

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

  test "pending deletion requests still count toward governed owner lifecycle safety" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, second_owner} =
             Accounts.create_user(
               %{
                 display_name: "Pending deletion owner",
                 email: "pending-deletion-owner@example.test",
                 password: "correct-horse-pending-owner",
                 role: "admin"
               },
               subject
             )

    assert {:ok, second_owner} =
             Accounts.change_user(
               second_owner.id,
               %{version: second_owner.lock_version, role: "owner", reason: "share ownership"},
               subject
             )

    assert {:ok, %{request: pending_request}} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: second_owner.id,
                 reason: "Pending request must not remove owner capacity"
               },
               subject
             )

    assert pending_request.status == :pending

    assert {:ok, %{user: demoted}} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{
                 version: account.user.lock_version,
                 role: "admin",
                 reason: "pending request still leaves another owner"
               },
               subject
             )

    assert demoted.role == :admin
  end

  test "approved deletion requests are excluded from governed owner lifecycle safety" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, second_owner} =
             Accounts.create_user(
               %{
                 display_name: "Approved deletion owner",
                 email: "approved-deletion-owner@example.test",
                 password: "correct-horse-approved-owner",
                 role: "admin"
               },
               subject
             )

    assert {:ok, second_owner} =
             Accounts.change_user(
               second_owner.id,
               %{version: second_owner.lock_version, role: "owner", reason: "share ownership"},
               subject
             )

    assert {:ok, %{request: request}} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: second_owner.id,
                 reason: "Approved owner deletion must reduce owner capacity"
               },
               subject
             )

    assert {:ok, approved} =
             Governance.transition_deletion_request(
               request.id,
               %{
                 version: request.lock_version,
                 status: "approved",
                 transition_reason: "approve owner deletion"
               },
               subject
             )

    assert approved.status == :approved

    assert {:error, :last_owner_required} =
             Governance.change_user_lifecycle_view(
               account.user.id,
               %{
                 version: account.user.lock_version,
                 role: "admin",
                 reason: "must preserve an effective owner"
               },
               subject
             )

    assert Repo.get!(User, account.user.id).role == :owner
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

  test "a user legal hold blocks deletion of that user's message" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "held-message-#{System.unique_integer([:positive])}",
                 body: "preserved evidence"
               },
               subject
             )

    assert {:ok, _hold} =
             Governance.create_legal_hold(
               %{
                 name: "User evidence hold",
                 reason: "Preserve all content authored by this user",
                 scope_type: "user",
                 subject_user_id: account.user.id
               },
               subject
             )

    assert {:ok, request_result} =
             Governance.create_deletion_request(
               %{
                 target_type: "message",
                 message_id: message.id,
                 reason: "Requested message deletion"
               },
               subject
             )

    assert {:ok, _approved} =
             Governance.transition_deletion_request(
               request_result.request.id,
               %{
                 version: request_result.request.lock_version,
                 status: "approved",
                 transition_reason: "Request identity verified"
               },
               subject
             )

    assert {:error, :legal_hold_active} =
             Governance.claim_deletion_request(
               request_result.request.id,
               :"Elixir.CommsWorkers.DeletionWorker"
             )
  end

  test "direct message deletion honors tenant, user, and conversation legal holds" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "direct-held-message",
                 body: "preserve direct deletion evidence"
               },
               subject
             )

    hold_attrs = [
      %{scope_type: "tenant"},
      %{scope_type: "user", subject_user_id: account.user.id},
      %{scope_type: "conversation", conversation_id: account.conversation.id}
    ]

    Enum.with_index(hold_attrs, 1)
    |> Enum.each(fn {scope_attrs, index} ->
      assert {:ok, %{hold: hold}} =
               Governance.create_legal_hold(
                 Map.merge(scope_attrs, %{
                   name: "Direct deletion hold #{index}",
                   reason: "Preserve content while direct deletion is evaluated"
                 }),
                 subject
               )

      assert {:error, :legal_hold_active} = Governance.delete_message(message.id, subject)

      assert {:ok, released} =
               Governance.release_legal_hold(
                 hold.id,
                 %{
                   version: hold.lock_version,
                   release_reason: "Direct deletion regression check completed"
                 },
                 subject
               )

      assert released.status == :released
    end)

    assert {:ok, deleted} = Governance.delete_message(message.id, subject)
    assert deleted.status == :deleted
  end

  defp authenticated_subject(account, user, device_name) do
    password_suffix = user.email |> String.split(["member-", "@"], trim: true) |> hd()
    password = "correct-horse-battery-#{password_suffix}"

    {:ok, result} =
      Accounts.authenticate(account.tenant.slug, user.email, password, %{
        name: device_name,
        platform: "test"
      })

    Accounts.subject_for_session(result.session)
  end

  defp tenant_audit_count(tenant_id) do
    Audit.count(%{tenant_id: tenant_id})
  end
end
