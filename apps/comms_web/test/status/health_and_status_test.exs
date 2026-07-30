defmodule CommsWeb.Status.HealthAndStatusTest do
  use CommsWeb.StatusCase

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :operations

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
    account = Fixtures.account_fixture()
    previous_enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    previous_slug = Application.get_env(:comms_core, :instant_room_tenant_slug)
    Application.put_env(:comms_core, :instant_rooms_enabled, true)
    Application.put_env(:comms_core, :instant_room_tenant_slug, account.tenant.slug)

    on_exit(fn ->
      restore_env(:instant_rooms_enabled, previous_enabled)
      restore_env(:instant_room_tenant_slug, previous_slug)
    end)

    conn = get(conn, "/api/v1/status")

    assert %{
             "service" => "k-comms",
             "capabilities" => %{
               "audio_calls" => audio_available,
               "guest_links" => true,
               "instant_rooms" => true,
               "secure_account_actions" => true,
               "secure_media_actions" => true,
               "video_calls" => video_available
             }
           } = json_response(conn, 200)

    assert audio_available == video_available
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "worker-src 'self'"
    assert policy =~ "manifest-src 'self'"
    assert policy =~ "ws://127.0.0.1:7880"

    assert get_resp_header(conn, "permissions-policy") == [
             "camera=(self), microphone=(self), display-capture=(self), geolocation=()"
           ]
  end

  test "GET /metrics", %{conn: conn} do
    conn = get(conn, "/metrics")
    assert response(conn, 200) =~ "k_comms_auth_success_total"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/plain"
  end
end
