defmodule CommsWeb.Administration.GovernedIdentityValidationTest do
  use CommsWeb.ConnCase, async: false

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :administration

  test "invalid governed display names return validation details without changing the user" do
    account = Fixtures.account_fixture()
    managed_user = Fixtures.user_fixture(account).user
    Fixtures.step_up(account)

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    response =
      authenticated_conn(token)
      |> patch("/api/v1/admin/users/#{managed_user.id}", %{
        version: managed_user.lock_version,
        display_name: "",
        reason: "reject an invalid lifecycle update"
      })
      |> json_response(422)

    assert response["error"]["code"] == "validation_failed"
    assert "can't be blank" in response["error"]["meta"]["display_name"]

    unchanged_user =
      authenticated_conn(token)
      |> get("/api/v1/admin/users")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.find(&(&1["id"] == managed_user.id))

    assert unchanged_user["display_name"] == managed_user.display_name
    assert unchanged_user["version"] == managed_user.lock_version
  end

  defp authenticated_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
