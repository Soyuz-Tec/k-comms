defmodule CommsWeb.StatusControllerTest do
  use CommsWeb.ConnCase, async: true
  test "GET /health/live", %{conn: conn} do
    conn = get(conn, "/health/live")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
  test "GET /api/v1/status", %{conn: conn} do
    conn = get(conn, "/api/v1/status")
    assert %{"service" => "k-comms"} = json_response(conn, 200)
  end
end
