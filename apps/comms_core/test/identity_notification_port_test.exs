defmodule CommsCore.Accounts.NotificationPortTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.{
    Device,
    NotificationCommand,
    NotificationPort,
    PasswordRecoveryRequest,
    Session,
    User
  }

  alias CommsCore.Notifications.Intent
  alias CommsCore.Security.Password
  alias CommsCore.{Accounts, Audit, Notifications, PasswordRecovery, Repo}
  alias CommsTestSupport.Fixtures

  @p256dh "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
  @auth "AAECAwQFBgcICQoLDA0ODw"

  defmodule FailingAdapter do
    @behaviour CommsCore.Accounts.NotificationPort

    @impl true
    def execute(%CommsCore.Accounts.NotificationCommand{}),
      do: {:error, :forced_notification_failure}
  end

  defmodule WriteThenFailAdapter do
    @behaviour CommsCore.Accounts.NotificationPort

    @impl true
    def execute(%CommsCore.Accounts.NotificationCommand{} = command) do
      case CommsCore.Notifications.execute(command) do
        :ok -> {:error, :forced_notification_failure}
        {:ok, _receipt} -> {:error, :forced_notification_failure}
        {:error, _reason} = error -> error
      end
    end
  end

  setup do
    previous_adapter = Application.fetch_env(:comms_core, :identity_notification_adapter)
    Application.put_env(:comms_core, :identity_notification_adapter, CommsCore.Notifications)

    on_exit(fn ->
      case previous_adapter do
        {:ok, adapter} ->
          Application.put_env(:comms_core, :identity_notification_adapter, adapter)

        :error ->
          Application.delete_env(:comms_core, :identity_notification_adapter)
      end
    end)

    :ok
  end

  test "commands redact destinations and the owner adapter requires a caller transaction" do
    account = Fixtures.account_fixture()
    destination = "private-recovery-address@example.test"

    recovery =
      NotificationCommand.password_recovery(
        account.tenant.id,
        account.user.id,
        destination,
        Ecto.UUID.generate()
      )

    refute inspect(recovery) =~ destination
    assert {:error, :transaction_required} = NotificationPort.execute(recovery)

    # The Identity-owned dispatcher enforces the transaction before invoking
    # any configured implementation, not only the default Notifications owner.
    Application.put_env(:comms_core, :identity_notification_adapter, FailingAdapter)

    assert {:error, :transaction_required} =
             account.tenant.id
             |> NotificationCommand.device_revoked(
               account.user.id,
               account.device.id,
               "device_revoked"
             )
             |> NotificationPort.execute()

    assert {:error, :transaction_required} =
             account.tenant.id
             |> NotificationCommand.user_access_revoked(
               account.user.id,
               "password_recovery"
             )
             |> NotificationPort.execute()
  end

  test "a failed recovery notification rolls back request, intent, job, and audit artifacts" do
    account = Fixtures.account_fixture()
    initial_job_count = Repo.aggregate(Oban.Job, :count)

    Application.put_env(
      :comms_core,
      :identity_notification_adapter,
      WriteThenFailAdapter
    )

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    refute Repo.exists?(
             from(request in PasswordRecoveryRequest,
               where:
                 request.tenant_id == ^account.tenant.id and
                   request.user_id == ^account.user.id
             )
           )

    refute Repo.exists?(
             from(intent in Intent,
               where:
                 intent.tenant_id == ^account.tenant.id and
                   intent.user_id == ^account.user.id and
                   intent.event_type == ^PasswordRecovery.event_type()
             )
           )

    assert Repo.aggregate(Oban.Job, :count) == initial_job_count

    assert Audit.count(%{
             tenant_id: account.tenant.id,
             action: "password_recovery.request"
           }) == 0
  end

  test "a failed device notification rolls back device, session, push, and audit changes" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %{subscription: subscription}} =
             Notifications.register_push_subscription(push_subscription_attrs(), subject)

    Application.put_env(
      :comms_core,
      :identity_notification_adapter,
      WriteThenFailAdapter
    )

    assert {:error, :forced_notification_failure} =
             Accounts.revoke_device(account.device.id, subject)

    assert is_nil(Repo.get!(Device, account.device.id).revoked_at)
    assert is_nil(Repo.get!(Session, account.session.id).revoked_at)
    assert {:ok, [%{id: id, status: :active}]} = Notifications.list_push_subscriptions(subject)
    assert id == subscription.id

    assert Audit.count(%{
             tenant_id: account.tenant.id,
             action: "device.revoke",
             resource_id: account.device.id
           }) == 0
  end

  test "a failed governed lifecycle notification rolls back user, access, push, and audit changes" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.step_up(account)
    password = "correct-horse-lifecycle-rollback"

    assert {:ok, member} =
             Accounts.create_user(
               %{
                 display_name: "Lifecycle rollback member",
                 email: "lifecycle-rollback-member@example.test",
                 password: password,
                 role: "member"
               },
               owner_subject
             )

    assert {:ok, login} =
             Accounts.authenticate_view(
               account.tenant.slug,
               member.email,
               password,
               %{name: "Lifecycle rollback browser", platform: "test"}
             )

    assert {:ok, %{subject: member_subject}} = Accounts.access_context(login.session_id)

    assert {:ok, %{subscription: subscription}} =
             Notifications.register_push_subscription(
               push_subscription_attrs("lifecycle-rollback"),
               member_subject
             )

    Application.put_env(
      :comms_core,
      :identity_notification_adapter,
      WriteThenFailAdapter
    )

    assert {:error, :forced_notification_failure} =
             CommsCore.Governance.change_user_lifecycle_view(
               member.id,
               %{
                 version: member.lock_version,
                 status: "suspended",
                 reason: "prove lifecycle rollback"
               },
               owner_subject
             )

    unchanged = Repo.get!(User, member.id)
    assert unchanged.status == :active
    assert unchanged.lock_version == member.lock_version
    assert is_nil(Repo.get!(Device, login.device.id).revoked_at)
    assert is_nil(Repo.get!(Session, login.session_id).revoked_at)

    assert {:ok, [%{id: id, status: :active}]} =
             Notifications.list_push_subscriptions(member_subject)

    assert id == subscription.id

    assert Audit.count(%{
             tenant_id: account.tenant.id,
             action: "user.lifecycle_update",
             resource_id: member.id
           }) == 0
  end

  test "a failed reset notification rolls back token consumption, password, and access revocation" do
    account = Fixtures.account_fixture()
    old_password = fixture_password(account)
    new_password = "correct-horse-rollback-password"

    assert {:ok, %{subscription: subscription}} =
             Notifications.register_push_subscription(
               push_subscription_attrs(),
               Fixtures.subject(account)
             )

    assert :ok =
             PasswordRecovery.request(%{
               tenant_slug: account.tenant.slug,
               email: account.user.email
             })

    recovery = Repo.get_by!(PasswordRecoveryRequest, user_id: account.user.id)
    token = token_for_recovery(recovery)

    Application.put_env(
      :comms_core,
      :identity_notification_adapter,
      WriteThenFailAdapter
    )

    assert {:error, :forced_notification_failure} =
             PasswordRecovery.reset(%{token: token, new_password: new_password})

    assert is_nil(Repo.get!(PasswordRecoveryRequest, recovery.id).consumed_at)

    user = Repo.get!(User, account.user.id)
    assert Password.verify(old_password, user.password_hash)
    refute Password.verify(new_password, user.password_hash)

    assert is_nil(Repo.get!(Device, account.device.id).revoked_at)
    assert is_nil(Repo.get!(Session, account.session.id).revoked_at)

    assert {:ok, [%{id: id, status: :active}]} =
             Notifications.list_push_subscriptions(Fixtures.subject(account))

    assert id == subscription.id

    assert Audit.count(%{
             tenant_id: account.tenant.id,
             action: "password_recovery.consume",
             resource_id: recovery.id
           }) == 0
  end

  defp token_for_recovery(recovery) do
    assert {:ok, delivery} =
             PasswordRecovery.materialize_notification(%{
               tenant_id: recovery.tenant_id,
               user_id: recovery.user_id,
               recovery_request_id: recovery.id
             })

    delivery.payload["action_url"]
    |> URI.parse()
    |> Map.fetch!(:fragment)
    |> URI.decode_query()
    |> Map.fetch!("token")
  end

  defp push_subscription_attrs(suffix \\ "identity-notification-port") do
    %{
      endpoint: "https://push.example.test/send/#{suffix}",
      expiration_time: nil,
      keys: %{p256dh: @p256dh, auth: @auth}
    }
  end

  defp fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end
end
