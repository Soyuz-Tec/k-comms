defmodule CommsCore.Governance.RetentionPolicyTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Audit, Governance, Messaging, RuntimePorts}
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Governance.{RetentionPolicies, RetentionPolicy}
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :governance

  test "bounded candidate pages advance past existing deletion work without loading all history" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    old = DateTime.utc_now() |> DateTime.add(-40 * 86_400, :second)

    messages =
      for index <- 1..101 do
        assert {:ok, message} =
                 Messaging.accept_message(
                   %{
                     tenant_id: account.tenant.id,
                     conversation_id: account.conversation.id,
                     sender_user_id: account.user.id,
                     sender_device_id: account.device.id,
                     client_message_id: "bounded-retention-#{index}",
                     body: "synthetic retention fixture"
                   },
                   subject
                 )

        message
      end

    message_ids = messages |> Enum.map(& &1.id) |> Enum.sort()
    Repo.update_all(from(m in Message, where: m.id in ^message_ids), set: [inserted_at: old])

    for id <- Enum.take(message_ids, 100) do
      %DeletionRequest{}
      |> DeletionRequest.changeset(%{
        tenant_id: account.tenant.id,
        requested_by_user_id: account.user.id,
        message_id: id,
        target_type: :message,
        reason: "Existing synthetic work",
        status: :approved,
        evidence: %{}
      })
      |> Repo.insert!()
    end

    assert {:ok, _} =
             Governance.create_retention_policy(%{name: "Bounded", retention_days: 30}, subject)

    worker = RuntimePorts.job_worker!(:retention)

    assert {:ok, %{enqueued: 0, scanned: 100, has_more: true, next_cursor: cursor}} =
             Governance.enqueue_due_retention(account.tenant.id, worker)

    assert cursor["message_id"] == Enum.at(message_ids, 99)

    assert {:ok, %{enqueued: 1, scanned: 1, has_more: false}} =
             Governance.enqueue_due_retention(account.tenant.id, worker, cursor)

    assert Repo.get_by!(DeletionRequest,
             tenant_id: account.tenant.id,
             message_id: List.last(message_ids)
           ).status == :approved

    assert {:error, :invalid_retention_cursor} =
             Governance.enqueue_due_retention(account.tenant.id, worker, %{"inserted_at" => 123})

    assert {:error, :forbidden} =
             Governance.enqueue_due_retention(account.tenant.id, __MODULE__, cursor)
  end

  test "failed initial scan scheduling rolls back the policy and its success audit" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:error, :schedule_unavailable} =
             RetentionPolicies.create_retention_policy(
               %{name: "Atomic retention", retention_days: 30, idempotency_key: "atomic-policy"},
               subject,
               fn _changeset ->
                 assert Repo.in_transaction?()
                 {:error, :schedule_unavailable}
               end
             )

    refute Repo.get_by(RetentionPolicy,
             tenant_id: account.tenant.id,
             idempotency_key: "atomic-policy"
           )

    refute Repo.exists?(
             from(a in CommsCore.Audit.AuditEvent,
               where: a.tenant_id == ^account.tenant.id and a.action == "retention_policy.create"
             )
           )
  end

  test "failed update scheduling rolls back policy version and success audit" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, %{policy: policy}} =
             Governance.create_retention_policy(
               %{name: "Original policy", retention_days: 30},
               subject
             )

    assert {:error, :schedule_unavailable} =
             RetentionPolicies.update_retention_policy(
               policy.id,
               %{version: policy.lock_version, retention_days: 10},
               subject,
               fn _changeset ->
                 assert Repo.in_transaction?()
                 {:error, :schedule_unavailable}
               end
             )

    persisted = Repo.get!(RetentionPolicy, policy.id)
    assert persisted.retention_days == 30
    assert persisted.lock_version == policy.lock_version

    refute Repo.exists?(
             from(a in CommsCore.Audit.AuditEvent,
               where: a.resource_id == ^policy.id and a.action == "retention_policy.update"
             )
           )
  end

  test "idempotent policy replay repairs a missing scan instead of reporting unscheduled success" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    attrs = %{name: "Replayed policy", retention_days: 30, idempotency_key: "repair-policy"}
    assert {:ok, %{policy: policy}} = Governance.create_retention_policy(attrs, subject)
    worker = RuntimePorts.job_worker_name!(:retention)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == ^worker))

    assert {:error, :schedule_unavailable} =
             RetentionPolicies.create_retention_policy(attrs, subject, fn _ ->
               {:error, :schedule_unavailable}
             end)

    assert {:ok, %{policy: replayed, replayed: true}} =
             Governance.create_retention_policy(attrs, subject)

    assert replayed.id == policy.id

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 j.worker == ^worker and fragment("?->>'tenant_id'", j.args) == ^account.tenant.id
             )
           )
  end

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
