defmodule CommsCore.OperationsAuthorizationTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Audit, Integrations, Notifications, Operations}
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  test "release metadata accepts only a full immutable Git revision" do
    previous = System.get_env("K_COMMS_RELEASE_REVISION")

    on_exit(fn ->
      if previous,
        do: System.put_env("K_COMMS_RELEASE_REVISION", previous),
        else: System.delete_env("K_COMMS_RELEASE_REVISION")
    end)

    System.put_env("K_COMMS_RELEASE_REVISION", String.duplicate("A", 40))
    assert Operations.release_revision() == String.duplicate("a", 40)

    System.put_env("K_COMMS_RELEASE_REVISION", "main")
    assert Operations.release_revision() == "development"
  end

  test "owner facades preserve tenant-role and step-up authorization matrices" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)

    assert :ok = Integrations.authorize_read(owner_subject)
    assert :ok = Notifications.authorize_tenant_scope(owner_subject)
    assert :ok = Operations.authorize_tenant_operations(owner_subject)
    assert {:error, :step_up_required} = Integrations.authorize_manage(owner_subject)

    assert {:error, :step_up_required} =
             Notifications.authorize_delivery_management(owner_subject)

    stepped_up_owner = Fixtures.step_up(account, owner_subject)
    assert :ok = Integrations.authorize_manage(stepped_up_owner)
    assert :ok = Notifications.authorize_delivery_management(stepped_up_owner)

    admin_password = "correct-horse-owner-policy-admin"

    admin_subject =
      create_login_subject(
        account,
        stepped_up_owner,
        :admin,
        "owner-policy-admin@example.test",
        admin_password
      )

    assert :ok = Integrations.authorize_read(admin_subject)
    assert :ok = Notifications.authorize_tenant_scope(admin_subject)
    assert :ok = Operations.authorize_tenant_operations(admin_subject)
    assert {:error, :step_up_required} = Integrations.authorize_manage(admin_subject)

    assert {:error, :step_up_required} =
             Notifications.authorize_delivery_management(admin_subject)

    assert {:ok, _session} = Accounts.step_up(%{current_password: admin_password}, admin_subject)
    assert :ok = Integrations.authorize_manage(admin_subject)
    assert :ok = Notifications.authorize_delivery_management(admin_subject)

    member_subject =
      create_login_subject(
        account,
        stepped_up_owner,
        :member,
        "owner-policy-member@example.test",
        "correct-horse-owner-policy-member"
      )

    assert {:error, :forbidden} = Integrations.authorize_read(member_subject)
    assert {:error, :forbidden} = Integrations.authorize_manage(member_subject)
    assert {:error, :forbidden} = Notifications.authorize_tenant_scope(member_subject)
    assert {:error, :forbidden} = Notifications.authorize_delivery_management(member_subject)
    assert {:error, :forbidden} = Operations.authorize_tenant_operations(member_subject)

    denied_permissions =
      Audit.list(%{
        tenant_id: account.tenant.id,
        actor_user_id: member_subject.user_id,
        action: "authorization.denied",
        limit: 20
      })
      |> Enum.map(& &1.metadata["permission"])
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               "administer_tenant",
               "manage_integrations",
               "manage_notification_delivery",
               "read_integrations",
               "read_tenant_notifications"
             ]),
             denied_permissions
           )
  end

  test "operations snapshot is tenant-scoped and exposes no destination or secret material" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    previous_secret = Application.get_env(:comms_core, :platform_role_management_secret)
    secret = String.duplicate("operations-platform-secret-", 2)

    Application.put_env(:comms_core, :platform_role_management_secret, secret)

    on_exit(fn ->
      if previous_secret,
        do: Application.put_env(:comms_core, :platform_role_management_secret, previous_secret),
        else: Application.delete_env(:comms_core, :platform_role_management_secret)
    end)

    assert {:ok, snapshot} = Operations.snapshot(subject)
    assert is_list(snapshot.queues)
    assert is_map(snapshot.notifications)
    assert is_map(snapshot.webhooks)
    assert is_map(snapshot.attachments)

    encoded = inspect(snapshot)
    refute encoded =~ "password_hash"
    refute encoded =~ "destination"
    refute encoded =~ "ciphertext"
    assert {:error, :forbidden} = Operations.platform_snapshot(subject)

    assert {:ok, _user} =
             Accounts.set_platform_role_from_console(account.user.id, :platform_operator, %{
               grant_token: secret,
               actor: "operations-test",
               reason: "verify platform operations authorization",
               ttl_seconds: 3600
             })

    assert {:ok, platform} =
             account.session
             |> Accounts.subject_for_session()
             |> Operations.platform_snapshot()

    assert platform.database.status == :available
    assert is_binary(platform.release_revision)
  end

  defp create_login_subject(account, owner_subject, role, email, password) do
    assert {:ok, user} =
             Accounts.create_user(
               %{
                 display_name: "Authorization policy user",
                 email: email,
                 password: password,
                 role: Atom.to_string(role)
               },
               owner_subject
             )

    assert {:ok, authentication} =
             Accounts.authenticate_view(account.tenant.slug, user.email, password, %{
               name: "Authorization policy browser",
               platform: "test"
             })

    {:ok, access_context} = Accounts.access_context(authentication.session_id)
    access_context.subject
  end
end
