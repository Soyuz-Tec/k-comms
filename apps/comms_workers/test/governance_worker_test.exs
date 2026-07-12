defmodule CommsWorkers.GovernanceWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.User
  alias CommsCore.Messaging.Message
  alias CommsCore.{Administration, Governance, Messaging, Repo}
  alias CommsTestSupport.Fixtures

  test "deletion worker performs the authoritative deletion and generates evidence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    target = Fixtures.user_fixture(account)

    assert {:ok, request_result} =
             Governance.create_deletion_request(
               %{
                 target_type: "user",
                 subject_user_id: target.user.id,
                 reason: "Verified account erasure request"
               },
               subject
             )

    assert {:ok, approved} =
             Governance.transition_deletion_request(
               request_result.request.id,
               %{
                 version: request_result.request.lock_version,
                 status: "approved",
                 transition_reason: "Identity and request scope verified"
               },
               subject
             )

    assert approved.status == :approved

    assert :ok =
             CommsWorkers.DeletionWorker.perform(%Oban.Job{
               args: %{"deletion_request_id" => approved.id}
             })

    deleted_user = Repo.get!(User, target.user.id)
    assert deleted_user.status == :deleted
    assert deleted_user.display_name == "Deleted user"
    refute deleted_user.email == target.user.email

    [completed] = elem(Governance.list_deletion_requests(%{status: "completed"}, subject), 1)
    assert completed.id == approved.id
    assert completed.evidence["executor"] == "CommsWorkers.DeletionWorker"
  end

  test "retention worker turns expired messages into durable deletion jobs" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    assert {:ok, message} =
             Messaging.accept_message(
               %{
                 tenant_id: account.tenant.id,
                 conversation_id: account.conversation.id,
                 sender_user_id: account.user.id,
                 sender_device_id: account.device.id,
                 client_message_id: "expired-retention-message",
                 body: "expired content"
               },
               subject
             )

    old_timestamp =
      DateTime.add(DateTime.utc_now(), -172_800, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(from(m in Message, where: m.id == ^message.id),
      set: [inserted_at: old_timestamp]
    )

    assert {:ok, _settings} =
             Administration.update_tenant_settings(
               %{version: 1, default_retention_days: 1},
               subject
             )

    assert :ok =
             CommsWorkers.RetentionWorker.perform(%Oban.Job{
               args: %{"tenant_id" => account.tenant.id}
             })

    request =
      Repo.get_by!(CommsCore.Governance.DeletionRequest,
        tenant_id: account.tenant.id,
        message_id: message.id,
        target_type: :message
      )

    assert request.status == :approved

    assert :ok =
             CommsWorkers.DeletionWorker.perform(%Oban.Job{
               args: %{"deletion_request_id" => request.id}
             })

    assert Repo.get!(Message, message.id).status == :deleted
  end
end
