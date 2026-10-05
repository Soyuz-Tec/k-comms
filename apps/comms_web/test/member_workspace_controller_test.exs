defmodule CommsWeb.MemberWorkspaceControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Accounts.MemberWorkspace
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "private read has no persistence effect and requires a current human session" do
    account = Fixtures.account_fixture()
    conn = account |> authenticated_conn() |> get("/api/v1/me/workspace")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"data" => data} = json_response(conn, 200)
    assert data["version"] == 0
    assert data["contacts"] == []
    assert data["groups"] == []
    assert data["onboarding"]["dismissed_at"] == nil
    assert data["limits"] == %{"contacts" => 500, "groups" => 20, "members_per_group" => 50}
    refute Repo.exists?(MemberWorkspace)
    assert build_conn() |> get("/api/v1/me/workspace") |> response(401)
    assert build_conn() |> put("/api/v1/me/workspace", %{}) |> response(401)
    assert build_conn() |> patch("/api/v1/me/onboarding", %{}) |> response(401)
  end

  test "contacts and groups stay private and stale writes cannot replace the saved aggregate" do
    account = Fixtures.account_fixture()
    password = "private-contact-controller-password-1234"

    other =
      Fixtures.user_fixture(account, %{
        display_name: "Private contact",
        password_hash: CommsCore.Security.Password.hash(password)
      })

    assert {:ok, other_login} =
             CommsCore.Accounts.authenticate_view(
               account.tenant.slug,
               other.user.email,
               password,
               %{}
             )

    group_id = Ecto.UUID.generate()

    attrs = %{
      version: 0,
      contact_ids: [other.user.id],
      groups: [%{id: group_id, name: "My private group", member_ids: [other.user.id]}]
    }

    written = account |> authenticated_conn() |> put("/api/v1/me/workspace", attrs)
    assert get_resp_header(written, "cache-control") == ["no-store"]
    assert %{"data" => saved} = json_response(written, 200)
    assert saved["version"] == 1
    assert saved["contacts"] == [%{"id" => other.user.id, "display_name" => "Private contact"}]
    assert [%{"id" => ^group_id, "name" => "My private group"}] = saved["groups"]
    refute inspect(saved) =~ other.user.email

    conflict =
      account
      |> authenticated_conn()
      |> put("/api/v1/me/workspace", %{version: 0, contact_ids: [], groups: []})

    assert json_response(conflict, 409)["error"]["code"] == "stale_version"

    assert json_response(account |> authenticated_conn() |> get("/api/v1/me/workspace"), 200)[
             "data"
           ]["groups"] == saved["groups"]

    assert json_response(
             other_login |> authenticated_result_conn() |> get("/api/v1/me/workspace"),
             200
           )[
             "data"
           ]["contacts"] == []
  end

  test "foreign contacts and absent versions are rejected without private state" do
    account = Fixtures.account_fixture()
    foreign = Fixtures.account_fixture()

    missing =
      account
      |> authenticated_conn()
      |> put("/api/v1/me/workspace", %{contact_ids: [], groups: []})

    assert json_response(missing, 428)["error"]["code"] == "version_required"

    rejected =
      account
      |> authenticated_conn()
      |> put("/api/v1/me/workspace", %{version: 0, contact_ids: [foreign.user.id], groups: []})

    assert json_response(rejected, 409)["error"]["code"] == "contact_unavailable"
    refute Repo.exists?(MemberWorkspace)
  end

  test "onboarding dismissal is versioned and an obsolete reset cannot undo it" do
    account = Fixtures.account_fixture()

    saved =
      account
      |> authenticated_conn()
      |> patch("/api/v1/me/onboarding", %{version: 0, action: "dismiss"})
      |> json_response(200)

    assert saved["data"]["version"] == 1
    assert is_binary(saved["data"]["onboarding"]["dismissed_at"])

    stale =
      account
      |> authenticated_conn()
      |> patch("/api/v1/me/onboarding", %{version: 0, action: "reset"})

    assert json_response(stale, 409)["error"]["code"] == "stale_version"

    resumed =
      account
      |> authenticated_conn()
      |> patch("/api/v1/me/onboarding", %{version: 1, action: "resume"})
      |> json_response(200)

    assert resumed["data"]["version"] == 2
    assert resumed["data"]["onboarding"]["dismissed_at"] == nil
  end

  defp authenticated_conn(account) do
    account |> Fixtures.authentication_result() |> authenticated_result_conn()
  end

  defp authenticated_result_conn(authentication) do
    token =
      authentication
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
