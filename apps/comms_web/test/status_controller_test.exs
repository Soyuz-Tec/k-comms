defmodule CommsWeb.StatusControllerTest do
  use CommsWeb.ConnCase, async: true

  test "GET /health/live", %{conn: conn} do
    conn = get(conn, "/health/live")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /api/v1/status", %{conn: conn} do
    conn = get(conn, "/api/v1/status")
    assert %{"service" => "k-comms"} = json_response(conn, 200)
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "frame-ancestors 'none'"
  end

  test "GET /metrics", %{conn: conn} do
    conn = get(conn, "/metrics")
    assert response(conn, 200) =~ "k_comms_auth_success_total"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/plain"
  end

  test "unknown API routes stay JSON 404s", %{conn: conn} do
    conn = get(conn, "/api/v1/does-not-exist")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end
end
