defmodule CommsCore.Accounts.PlatformAccessTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.{PlatformAccess, PlatformRoleGrant, User}
  alias CommsTestSupport.Fixtures

  test "resolves active grants from preloaded and unloaded users" do
    account = Fixtures.account_fixture()

    expires_at =
      DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

    grant =
      %PlatformRoleGrant{}
      |> PlatformRoleGrant.changeset(%{
        id: Ecto.UUID.generate(),
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        role: :platform_operator,
        expires_at: expires_at
      })
      |> Repo.insert!()

    unloaded_user = Repo.get!(User, account.user.id)
    assert %Ecto.Association.NotLoaded{} = unloaded_user.platform_role_grant

    assert %{
             platform_role: :platform_operator,
             platform_role_expires_at: ^expires_at
           } = PlatformAccess.for_user(unloaded_user)

    assert %{
             platform_role_grant_id: grant_id,
             platform_role: :platform_operator,
             platform_role_expires_at: ^expires_at
           } = PlatformAccess.for_subject(unloaded_user)

    assert grant_id == grant.id

    preloaded_user = Repo.preload(unloaded_user, :platform_role_grant, force: true)

    assert PlatformAccess.for_user(preloaded_user) ==
             PlatformAccess.for_user(unloaded_user)

    assert %{
             platform_role_grant_id: nil,
             platform_role: nil,
             platform_role_expires_at: nil
           } =
             unloaded_user
             |> Map.put(:platform_role_grant, nil)
             |> PlatformAccess.for_subject()

    assert %{platform_role: nil, platform_role_expires_at: nil} =
             unloaded_user
             |> Map.put(:tenant_id, Ecto.UUID.generate())
             |> PlatformAccess.for_user()
  end

  test "fails closed for an expired preloaded grant" do
    account = Fixtures.account_fixture()

    expired_grant = %PlatformRoleGrant{
      id: Ecto.UUID.generate(),
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      role: :security_operator,
      expires_at:
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)
    }

    assert %{platform_role: nil, platform_role_expires_at: nil} =
             account.user
             |> Map.put(:platform_role_grant, expired_grant)
             |> PlatformAccess.for_user()
  end
end
