defmodule CommsCore.Accounts.UserDirectoryTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{User, UserView}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "active user IDs include human and service identities only in the exact tenant" do
    account = Fixtures.account_fixture()
    active_human = Fixtures.user_fixture(account).user
    suspended_human = Fixtures.user_fixture(account, %{status: :suspended}).user
    active_service = service_user_fixture(account, "Active Service")
    other_account = Fixtures.account_fixture()

    requested_ids = [
      suspended_human.id,
      active_service.id,
      other_account.user.id,
      active_human.id,
      account.user.id,
      active_human.id
    ]

    assert Accounts.resolve_active_user_ids(account.tenant.id, requested_ids) ==
             Enum.sort([account.user.id, active_human.id, active_service.id])

    assert [] == Accounts.resolve_active_user_ids(other_account.tenant.id, [active_human.id])
    assert [] == Accounts.resolve_active_user_ids(account.tenant.id, [])
    assert [] == Accounts.resolve_active_user_ids(nil, requested_ids)
  end

  test "user views include suspended identities and remain deterministic, scoped, and private" do
    account = Fixtures.account_fixture(%{display_name: "Zulu Owner"})
    alpha = Fixtures.user_fixture(account, %{display_name: "Alpha Member"}).user
    same_a = Fixtures.user_fixture(account, %{display_name: "Same Name"}).user
    same_b = Fixtures.user_fixture(account, %{display_name: "Same Name"}).user

    suspended =
      Fixtures.user_fixture(account, %{display_name: "Suspended Member", status: :suspended}).user

    service = service_user_fixture(account, "Service Directory")
    other_account = Fixtures.account_fixture(%{display_name: "Foreign Alpha"})

    own_users = [account.user, alpha, same_a, same_b, suspended, service]

    requested_ids = [
      same_b.id,
      other_account.user.id,
      suspended.id,
      service.id,
      same_a.id,
      alpha.id,
      account.user.id,
      same_a.id
    ]

    views = Accounts.resolve_user_views(account.tenant.id, requested_ids)

    expected_ids =
      own_users
      |> Enum.sort_by(&{&1.display_name, &1.id})
      |> Enum.map(& &1.id)

    assert Enum.map(views, & &1.id) == expected_ids
    assert Enum.all?(views, &match?(%UserView{}, &1))
    assert Enum.find(views, &(&1.id == suspended.id)).status == :suspended
    assert Enum.find(views, &(&1.id == service.id)).email == nil

    Enum.each(views, fn view ->
      projected = Map.from_struct(view)
      refute Map.has_key?(projected, :password_hash)
      refute Map.has_key?(projected, :__meta__)
      refute match?(%User{}, view)
    end)

    refute inspect(views) =~ account.user.password_hash
    refute inspect(views) =~ service.email

    assert [] == Accounts.resolve_user_views(other_account.tenant.id, [alpha.id])
    assert [] == Accounts.resolve_user_views(account.tenant.id, [])
    assert [] == Accounts.resolve_user_views(nil, requested_ids)
  end

  defp service_user_fixture(account, display_name) do
    suffix = System.unique_integer([:positive, :monotonic])

    %User{}
    |> User.service_changeset(%{
      tenant_id: account.tenant.id,
      external_subject: "service:directory-#{suffix}",
      display_name: display_name,
      email: "directory-#{suffix}@service.invalid",
      account_type: :service,
      role: :member,
      status: :active
    })
    |> Repo.insert!()
  end
end
