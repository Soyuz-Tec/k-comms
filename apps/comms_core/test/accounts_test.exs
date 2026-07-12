defmodule CommsCore.AccountsTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Repo
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

  test "bootstraps a tenant and authenticates its owner" do
    account = Fixtures.account_fixture()

    assert account.tenant.status == :active
    assert account.user.role == :owner
    assert account.conversation.title == "General"
    assert is_binary(account.refresh_token)

    assert {:ok, authenticated} =
             Accounts.authenticate(
               account.tenant.slug,
               account.user.email,
               account_fixture_password(account),
               %{name: "Second browser", platform: "test"}
             )

    assert authenticated.user.id == account.user.id
    assert authenticated.device.user_id == account.user.id
    assert {:ok, refreshed} = Accounts.refresh_session(authenticated.refresh_token)
    assert refreshed.session.id == authenticated.session.id
    assert refreshed.refresh_token != authenticated.refresh_token
  end

  test "rejects invalid credentials" do
    account = Fixtures.account_fixture()

    assert {:error, :invalid_credentials} =
             Accounts.authenticate(account.tenant.slug, account.user.email, "not-the-password")
  end

  test "a refresh token succeeds only once under concurrent rotation" do
    account = Fixtures.account_fixture()

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Accounts.refresh_session(account.refresh_token) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_refresh_token}, &1)) == 7
    assert {:error, :invalid_refresh_token} = Accounts.refresh_session(account.refresh_token)
  end

  test "owners and admins create tenant-scoped users with audit evidence" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    admin_password = "correct-horse-admin-password"

    assert {:ok, admin} =
             Accounts.create_user(
               %{
                 tenant_id: Ecto.UUID.generate(),
                 display_name: "Workspace Admin",
                 email: "workspace-admin@example.test",
                 password: admin_password,
                 role: "admin"
               },
               owner_subject
             )

    assert admin.tenant_id == account.tenant.id
    assert admin.role == :admin
    assert Password.verify(admin_password, admin.password_hash)

    assert {:ok, admin_login} =
             Accounts.authenticate(
               account.tenant.slug,
               admin.email,
               admin_password,
               %{name: "Admin browser", platform: "test"}
             )

    admin_subject = Accounts.subject_for_session(admin_login.session)

    assert {:ok, member} =
             Accounts.create_user(
               %{
                 display_name: "Workspace Member",
                 email: "workspace-member@example.test",
                 password: "correct-horse-member-password"
               },
               admin_subject
             )

    assert member.tenant_id == account.tenant.id
    assert member.role == :member

    assert 2 ==
             AuditEvent
             |> where(
               [event],
               event.tenant_id == ^account.tenant.id and event.action == "user.create"
             )
             |> Repo.aggregate(:count)
  end

  defp account_fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end
end
