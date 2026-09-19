defmodule CommsWorkers.GovernanceWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.User
  alias CommsCore.Governance.DeletionRequest
  alias CommsCore.Messaging.Message
  alias CommsCore.{Administration, Governance, Messaging, Repo}
  alias CommsTestSupport.Fixtures

  test "reconciler pages a mixed overlapping tenant union and persists its continuation" do
    ids =
      for index <- 1..101 do
        tenant =
          Repo.insert!(%CommsCore.Administration.Tenant{
            name: "Synthetic page tenant",
            slug: "retention-page-#{Ecto.UUID.generate()}"
          })

        if rem(index, 3) != 0 do
          Repo.insert!(%CommsCore.Administration.TenantSettings{
            tenant_id: tenant.id,
            default_retention_days: 30
          })
        end

        if rem(index, 3) != 1 do
          Repo.insert!(%CommsCore.Governance.RetentionPolicy{
            tenant_id: tenant.id,
            name: "Synthetic policy",
            retention_days: 30
          })
        end

        tenant.id
      end
      |> Enum.sort()

    reconciler = CommsWorkers.RetentionReconcilerWorker
    assert :ok = reconciler.perform(%Oban.Job{args: %{}})

    child =
      Repo.one!(from(j in Oban.Job, where: j.worker == "CommsWorkers.RetentionReconcilerWorker"))

    assert child.args == %{"cursor" => Enum.at(ids, 99)}

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "CommsWorkers.RetentionWorker"),
             :count
           ) == 100

    assert :ok = reconciler.perform(child)

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "CommsWorkers.RetentionWorker"),
             :count
           ) == 101

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "CommsWorkers.RetentionReconcilerWorker"),
             :count
           ) == 1
  end

  test "reconciler repairs missing policy and tenant-default scans without duplicating live work" do
    policy_account = Fixtures.account_fixture()
    defaults_account = Fixtures.account_fixture()

    assert {:ok, _} =
             Governance.create_retention_policy(
               %{name: "Policy", retention_days: 30},
               Fixtures.step_up(policy_account)
             )

    assert {:ok, _} =
             Administration.update_tenant_settings(
               %{version: 1, default_retention_days: 30},
               Fixtures.step_up(defaults_account)
             )

    worker = "CommsWorkers.RetentionWorker"
    Repo.delete_all(from(j in Oban.Job, where: j.worker == ^worker))
    reconciler = CommsWorkers.RetentionReconcilerWorker
    assert {:error, :forbidden} = Governance.reconcile_retention_schedules(nil, __MODULE__)

    assert {:error, :invalid_retention_cursor} =
             Governance.reconcile_retention_schedules("invalid", reconciler)

    assert {:ok, %{repaired: 2, has_more: false}} =
             Governance.reconcile_retention_schedules(nil, reconciler)

    assert {:ok, %{repaired: 0}} = Governance.reconcile_retention_schedules(nil, reconciler)
    assert :ok = reconciler.perform(%Oban.Job{args: %{}})
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^worker), :count) == 2

    Repo.update_all(
      from(j in Oban.Job,
        where:
          j.worker == ^worker and fragment("?->>'tenant_id'", j.args) == ^policy_account.tenant.id
      ),
      set: [state: "discarded"]
    )

    assert {:ok, %{repaired: 1}} = Governance.reconcile_retention_schedules(nil, reconciler)

    assert {:ok, %{repaired: 0, has_more: false}} =
             Governance.reconcile_retention_schedules(
               Enum.max([policy_account.tenant.id, defaults_account.tenant.id]),
               reconciler
             )
  end

  test "retention persists a full excluded page cursor then returns to daily scans" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second)

    ids =
      for index <- 1..100 do
        {:ok, message} =
          Messaging.accept_message(
            %{
              tenant_id: account.tenant.id,
              conversation_id: account.conversation.id,
              sender_user_id: account.user.id,
              sender_device_id: account.device.id,
              client_message_id: "worker-page-#{index}",
              body: "Synthetic expired content"
            },
            subject
          )

        %DeletionRequest{}
        |> DeletionRequest.changeset(%{
          tenant_id: account.tenant.id,
          requested_by_user_id: account.user.id,
          target_type: :message,
          message_id: message.id,
          reason: "Existing synthetic deletion",
          status: :approved,
          evidence: %{}
        })
        |> Repo.insert!()

        message.id
      end

    Repo.update_all(from(m in Message, where: m.id in ^ids), set: [inserted_at: old])

    assert {:ok, _} =
             Administration.update_tenant_settings(
               %{version: 1, default_retention_days: 1},
               subject
             )

    worker = "CommsWorkers.RetentionWorker"
    Repo.delete_all(from(j in Oban.Job, where: j.worker == ^worker))
    job = %Oban.Job{args: %{"tenant_id" => account.tenant.id}}
    assert :ok = CommsWorkers.RetentionWorker.perform(job)
    [successor] = Repo.all(from(j in Oban.Job, where: j.worker == ^worker))
    assert successor.args["cursor"]["message_id"] == Enum.max(ids)
    assert DateTime.diff(successor.scheduled_at, DateTime.utc_now()) in -1..2

    assert :ok = CommsWorkers.RetentionWorker.perform(successor)

    daily =
      Repo.one!(
        from(j in Oban.Job,
          where: j.worker == ^worker and not fragment("? \\? 'cursor'", j.args)
        )
      )

    assert daily.args == %{"tenant_id" => account.tenant.id}
    assert DateTime.diff(daily.scheduled_at, DateTime.utc_now()) in 86_390..86_400
  end

  test "failed recurrence is retryable and does not report success" do
    account = Fixtures.account_fixture()
    job = %Oban.Job{args: %{"tenant_id" => account.tenant.id}}

    assert {:error, :queue_unavailable} =
             CommsWorkers.RetentionWorker.perform(job, fn _ -> {:error, :queue_unavailable} end)

    assert {:error, :retention_scheduling_failed} =
             CommsWorkers.RetentionWorker.perform(job, fn _ ->
               {:error, %{sensitive: "detail"}}
             end)

    assert :ok = CommsWorkers.RetentionWorker.perform(job)
  end

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
