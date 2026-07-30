defmodule CommsCore.Governance.RetentionPolicyTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Audit, Governance, Messaging, RuntimePorts}
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "retention policies are idempotent and require an audited reason for updates" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

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
  end

  test "retention coordination preserves governance-owned policy metadata" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "retention-boundary-message",
                 body: "expired content"
               },
               subject
             )

    cutoff_fixture = DateTime.utc_now() |> DateTime.add(-40 * 86_400, :second)

    Repo.update_all(
      from(persisted in Message, where: persisted.id == ^message.id),
      set: [inserted_at: cutoff_fixture]
    )

    assert {:ok, %{policy: policy}} =
             Governance.create_retention_policy(
               %{
                 name: "Conversation retention boundary",
                 scope_type: "conversation",
                 conversation_id: account.conversation.id,
                 retention_days: 30,
                 delete_attachments: false
               },
               subject
             )

    assert {:ok, %{enqueued: 1, scanned: 1, has_more: false}} =
             Governance.enqueue_due_retention(
               account.tenant.id,
               RuntimePorts.job_worker!(:retention)
             )

    request =
      Repo.get_by!(DeletionRequest,
        tenant_id: account.tenant.id,
        message_id: message.id,
        target_type: :message
      )

    assert request.status == :approved
    assert request.requested_by_user_id == account.user.id
    assert request.evidence["retention_policy_id"] == policy.id
    assert request.evidence["retention_delete_attachments"] == false
  end
end
