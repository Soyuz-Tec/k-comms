defmodule CommsCore.Accounts.NotificationAccessTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{Device, NotificationRecipient, User}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "notification recipients are minimal, redacted, active-human tenant projections" do
    account = Fixtures.account_fixture()
    active_member = Fixtures.user_fixture(account).user
    suspended_member = Fixtures.user_fixture(account, %{status: :suspended}).user
    service_user = service_user_fixture(account)
    other_account = Fixtures.account_fixture()

    recipients =
      Accounts.resolve_notification_recipients(account.tenant.id, [
        service_user.id,
        active_member.id,
        account.user.id,
        active_member.id,
        suspended_member.id,
        other_account.user.id
      ])

    assert Enum.map(recipients, & &1.user_id) ==
             Enum.sort([account.user.id, active_member.id])

    assert Enum.all?(recipients, &match?(%NotificationRecipient{}, &1))

    assert Enum.all?(recipients, fn recipient ->
             Map.from_struct(recipient) == %{
               user_id: recipient.user_id,
               email: recipient.email
             }
           end)

    Enum.each(recipients, fn recipient ->
      refute inspect(recipient) =~ recipient.email
    end)

    assert [] == Accounts.resolve_notification_recipients(account.tenant.id, [])
    assert [] == Accounts.resolve_notification_recipients(nil, [account.user.id])
  end

  test "eligible push devices preserve exact active-human tenant and user scope" do
    account = Fixtures.account_fixture()
    second_device = device_fixture(account.tenant.id, account.user.id, "Second")
    revoked_device = device_fixture(account.tenant.id, account.user.id, "Revoked", now())
    other_member = Fixtures.user_fixture(account).user
    other_member_device = device_fixture(account.tenant.id, other_member.id, "Other member")
    service_user = service_user_fixture(account)
    service_device = device_fixture(account.tenant.id, service_user.id, "Service")
    other_account = Fixtures.account_fixture()

    requested_ids = [
      service_device.id,
      account.device.id,
      other_account.device.id,
      revoked_device.id,
      second_device.id,
      other_member_device.id,
      second_device.id
    ]

    assert Accounts.notification_eligible_device_ids(
             account.tenant.id,
             account.user.id,
             requested_ids
           ) == Enum.sort([account.device.id, second_device.id])

    account.user
    |> User.changeset(%{status: :suspended})
    |> Repo.update!()

    assert [] ==
             Accounts.notification_eligible_device_ids(
               account.tenant.id,
               account.user.id,
               requested_ids
             )

    assert [] == Accounts.notification_eligible_device_ids(account.tenant.id, account.user.id, [])
    assert [] == Accounts.notification_eligible_device_ids(nil, account.user.id, requested_ids)
  end

  test "push registration identity lock requires a transaction and locks user before device" do
    account = Fixtures.account_fixture()

    assert {:error, :transaction_required} =
             Accounts.lock_push_registration_identity(
               account.tenant.id,
               account.user.id,
               account.device.id
             )

    parent = self()
    handler_id = {__MODULE__, :push_registration_identity_lock_order, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:comms_core, :repo, :query],
               fn _event, _measurements, metadata, test_pid ->
                 send(test_pid, {:push_identity_lock_query, Map.get(metadata, :query, "")})
               end,
               parent
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Accounts.lock_push_registration_identity(
                 account.tenant.id,
                 account.user.id,
                 account.device.id
               )
             end)

    queries = collect_lock_queries([])

    user_lock_index =
      Enum.find_index(queries, fn query ->
        String.contains?(query, ~s(FROM "users")) and String.contains?(query, "FOR SHARE")
      end)

    device_lock_index =
      Enum.find_index(queries, fn query ->
        String.contains?(query, ~s(FROM "devices")) and String.contains?(query, "FOR SHARE")
      end)

    assert is_integer(user_lock_index)
    assert is_integer(device_lock_index)
    assert user_lock_index < device_lock_index
  end

  test "push registration identity lock rejects foreign or inactive authority" do
    account = Fixtures.account_fixture()
    other_account = Fixtures.account_fixture()

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn ->
               Accounts.lock_push_registration_identity(
                 account.tenant.id,
                 account.user.id,
                 other_account.device.id
               )
             end)

    account.device
    |> Device.changeset(%{revoked_at: now()})
    |> Repo.update!()

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn ->
               Accounts.lock_push_registration_identity(
                 account.tenant.id,
                 account.user.id,
                 account.device.id
               )
             end)

    account.user
    |> User.changeset(%{status: :suspended})
    |> Repo.update!()

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn ->
               Accounts.lock_push_registration_identity(
                 account.tenant.id,
                 account.user.id,
                 account.device.id
               )
             end)
  end

  defp service_user_fixture(account) do
    suffix = System.unique_integer([:positive, :monotonic])

    %User{}
    |> User.service_changeset(%{
      tenant_id: account.tenant.id,
      external_subject: "service:notification-#{suffix}",
      display_name: "Notification Service #{suffix}",
      email: "notification-#{suffix}@service.invalid",
      account_type: :service,
      role: :member,
      status: :active
    })
    |> Repo.insert!()
  end

  defp device_fixture(tenant_id, user_id, name, revoked_at \\ nil) do
    %Device{}
    |> Device.changeset(%{
      tenant_id: tenant_id,
      user_id: user_id,
      name: name,
      platform: "test",
      revoked_at: revoked_at
    })
    |> Repo.insert!()
  end

  defp collect_lock_queries(acc) do
    receive do
      {:push_identity_lock_query, query} -> collect_lock_queries([query | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
