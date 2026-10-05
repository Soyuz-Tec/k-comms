defmodule CommsWeb.CalendarControllerTest do
  use CommsWeb.ConnCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsTestSupport.Fixtures

  test "real HTTP status is private, default disabled and contains no provider credentials" do
    account = Fixtures.account_fixture()
    conn = authenticated(account) |> get("/api/v1/calendar/connections")
    result = json_response(conn, 200)
    assert result["data"] == []
    assert result["meta"]["policy"]["export_allowed"] == false

    assert Enum.all?(
             result["meta"]["providers"],
             &(&1["configured"] == false and &1["qualified"] == false)
           )

    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    refute Jason.encode!(result) =~ "refresh_token"
    refute Jason.encode!(result) =~ "external_subject"
  end

  test "default-off authorization refuses provider effects and unauthenticated status is denied" do
    account = Fixtures.account_fixture()
    Fixtures.step_up(account)

    conn =
      authenticated(account)
      |> put_req_header("origin", "http://localhost:5173")
      |> post("/api/v1/calendar/oauth/google/authorize", %{
        export_policy_version: 1,
        purpose: "export"
      })

    assert json_response(conn, 503)["error"]["code"] == "calendar_provider_not_configured"
    assert build_conn() |> get("/api/v1/calendar/connections") |> response(401)
  end

  test "unknown or unbound callbacks redirect only to the fixed safe profile result" do
    conn =
      build_conn()
      |> get("/api/v1/calendar/oauth/google/callback", %{
        state: String.duplicate("x", 43),
        code: "synthetic-code"
      })

    assert redirected_to(conn, 303) == "/app/you?section=calendar&calendar_result=rejected"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  defp authenticated(account) do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end
end
