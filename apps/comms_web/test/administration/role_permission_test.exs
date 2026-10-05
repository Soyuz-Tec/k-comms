defmodule CommsWeb.Administration.RolePermissionTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.User
  alias CommsTestSupport.Fixtures
  @moduletag :integration

  test "HTTP catalog and preview expose bounded facts and leave mutation to the governed endpoint" do
    account = Fixtures.account_fixture()
    target = Fixtures.user_fixture(account).user
    Fixtures.step_up(account)
    token = token(account)
    catalog = conn(token) |> get("/api/v1/admin/role-permissions") |> json_response(200)
    assert length(catalog["data"]) == 6
    owner = Enum.find(catalog["data"], &(&1["role"] == "owner"))
    assert Enum.all?(owner["capabilities"], &(&1["scope"] == "tenant"))

    preview =
      conn(token)
      |> post(
        "/api/v1/admin/users/#{target.id}/role-preview",
        %{role: "security_admin", version: target.lock_version}
      )
      |> json_response(200)

    assert preview["data"]["advisory"]
    assert preview["data"]["current_role"] == "member"
    assert preview["data"]["requested_role"] == "security_admin"
    assert preview["data"]["current_version"] == target.lock_version

    assert Enum.map(preview["data"]["added"], & &1["capability"]) == [
             "manage_sessions",
             "audit_tenant"
           ]

    assert Repo.get!(User, target.id).role == :member

    stale =
      conn(token)
      |> post(
        "/api/v1/admin/users/#{target.id}/role-preview",
        %{role: "admin", version: target.lock_version + 1}
      )
      |> json_response(409)

    assert stale["error"]["code"] == "stale_version"
  end

  test "preview requires recent authority and revoked bearer credentials disclose no role facts" do
    account = Fixtures.account_fixture()
    target = Fixtures.user_fixture(account).user
    token = token(account)

    response =
      conn(token)
      |> post(
        "/api/v1/admin/users/#{target.id}/role-preview",
        %{role: "admin", version: target.lock_version}
      )
      |> json_response(428)

    assert response["error"]["code"] == "step_up_required"

    assert :ok =
             Accounts.revoke_own_session_command(account.session.id, Fixtures.subject(account))

    response = conn(token) |> get("/api/v1/admin/role-permissions") |> json_response(401)
    assert response["error"]["code"] == "unauthenticated"
  end

  defp token(account),
    do:
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

  defp conn(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
