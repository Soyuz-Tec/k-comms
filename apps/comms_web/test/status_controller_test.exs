defmodule CommsWeb.StatusControllerTest do
  use CommsWeb.ConnCase, async: false

  test "GET /health/live", %{conn: conn} do
    conn = get(conn, "/health/live")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /health/ready recognizes the supervised Oban instance", %{conn: conn} do
    conn = get(conn, "/health/ready")

    assert %{
             "status" => "ready",
             "checks" => %{
               "database" => %{"status" => "ok"},
               "runtime" => %{"status" => "ok", "jobs" => "ready"}
             }
           } = json_response(conn, 200)
  end

  test "GET /api/v1/status", %{conn: conn} do
    conn = get(conn, "/api/v1/status")

    assert %{
             "service" => "k-comms",
             "capabilities" => %{
               "audio_calls" => audio_available,
               "video_calls" => video_available
             }
           } = json_response(conn, 200)

    assert audio_available == video_available
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "ws://127.0.0.1:7880"

    assert get_resp_header(conn, "permissions-policy") == [
             "camera=(self), microphone=(self), geolocation=()"
           ]
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

  test "SPA fallback serves the built index as HTML", %{conn: conn} do
    index_path = Application.app_dir(:comms_web, "priv/static/app/index.html")
    previous = if File.exists?(index_path), do: File.read!(index_path)

    File.mkdir_p!(Path.dirname(index_path))
    File.write!(index_path, "<!doctype html><title>K-Comms test index</title>")

    on_exit(fn ->
      if previous do
        File.write!(index_path, previous)
      else
        File.rm(index_path)
      end
    end)

    response = get(conn, "/app/workspace")

    assert response(response, 200) =~ "K-Comms test index"
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "text/html"
  end
end
