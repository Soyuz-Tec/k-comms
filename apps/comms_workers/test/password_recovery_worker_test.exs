defmodule CommsWorkers.PasswordRecoveryWorkerTest.CaptureNotifications do
  @behaviour CommsIntegrations.Notifications

  @impl true
  def deliver(payload) do
    send(
      Application.fetch_env!(:comms_workers, :password_recovery_test_pid),
      {:delivery, payload}
    )

    {:ok, %{provider: "capture", provider_message_id: "recovery-test"}}
  end

  @impl true
  def status, do: %{status: :available, adapter: "capture"}
end

defmodule CommsWorkers.PasswordRecoveryWorkerTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.PasswordRecoveryRequest
  alias CommsCore.Notifications.Intent
  alias CommsCore.{PasswordRecovery, Repo}
  alias CommsTestSupport.Fixtures

  setup do
    previous_adapter = Application.get_env(:comms_integrations, :notification_adapter)
    previous_pid = Application.get_env(:comms_workers, :password_recovery_test_pid)

    Application.put_env(
      :comms_integrations,
      :notification_adapter,
      CommsWorkers.PasswordRecoveryWorkerTest.CaptureNotifications
    )

    Application.put_env(:comms_workers, :password_recovery_test_pid, self())

    on_exit(fn ->
      restore_env(:comms_integrations, :notification_adapter, previous_adapter)
      restore_env(:comms_workers, :password_recovery_test_pid, previous_pid)
    end)

    :ok
  end

  test "recovery URL is materialized only at dispatch and expired requests never reach provider" do
    account = Fixtures.account_fixture()

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    intent = Repo.get_by!(Intent, event_type: PasswordRecovery.event_type())
    refute Jason.encode!(intent.payload) =~ "token"
    refute Jason.encode!(intent.payload) =~ "action_url"

    assert :ok =
             CommsWorkers.NotificationWorker.perform(%Oban.Job{
               args: %{"intent_id" => intent.id}
             })

    assert_receive {:delivery, delivered}
    assert delivered.payload["action_url"] =~ "/reset-password#token="
    assert delivered.destination == account.user.email

    persisted = Repo.get!(Intent, intent.id)
    assert persisted.status == :delivered
    refute Jason.encode!(persisted.payload) =~ "token"
    refute Jason.encode!(persisted.payload) =~ "action_url"

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    expired_intent =
      Intent
      |> where([value], value.event_type == ^PasswordRecovery.event_type())
      |> order_by([value], desc: value.inserted_at)
      |> limit(1)
      |> Repo.one!()

    request_id = expired_intent.payload["recovery_request_id"]
    recovery = Repo.get!(PasswordRecoveryRequest, request_id)

    recovery
    |> PasswordRecoveryRequest.changeset(%{
      expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
    })
    |> Repo.update!()

    assert {:discard, :password_recovery_not_deliverable} =
             CommsWorkers.NotificationWorker.perform(%Oban.Job{
               args: %{"intent_id" => expired_intent.id}
             })

    refute_receive {:delivery, _payload}
  end

  defp restore_env(application, key, nil), do: Application.delete_env(application, key)
  defp restore_env(application, key, value), do: Application.put_env(application, key, value)
end
