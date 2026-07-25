defmodule CommsWeb.StatusControllerTest do
  use CommsWeb.ConnCase, async: false

  alias CommsIntegrations.Audio.LiveKitReadiness
  alias CommsCore.Administration.Tenant
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

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

  test "instant rooms capability fails closed unless enabled and configured", %{conn: conn} do
    account = Fixtures.account_fixture()
    previous_enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    previous_slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    on_exit(fn ->
      restore_env(:instant_rooms_enabled, previous_enabled)
      restore_env(:instant_room_tenant_slug, previous_slug)
    end)

    Application.put_env(:comms_core, :instant_rooms_enabled, false)
    Application.put_env(:comms_core, :instant_room_tenant_slug, account.tenant.slug)

    assert conn
           |> get("/api/v1/status")
           |> json_response(200)
           |> get_in(["capabilities", "instant_rooms"]) == false

    Application.put_env(:comms_core, :instant_rooms_enabled, true)
    Application.put_env(:comms_core, :instant_room_tenant_slug, "missing-tenant")

    assert build_conn()
           |> get("/api/v1/status")
           |> json_response(200)
           |> get_in(["capabilities", "instant_rooms"]) == false

    account.tenant
    |> Tenant.changeset(%{status: :suspended})
    |> Repo.update!()

    Application.put_env(:comms_core, :instant_room_tenant_slug, account.tenant.slug)

    assert build_conn()
           |> get("/api/v1/status")
           |> json_response(200)
           |> get_in(["capabilities", "instant_rooms"]) == false

    Application.put_env(:comms_core, :instant_rooms_enabled, true)
    Application.put_env(:comms_core, :instant_room_tenant_slug, " ")

    assert build_conn()
           |> get("/api/v1/status")
           |> json_response(200)
           |> get_in(["capabilities", "instant_rooms"]) == false
  end

  test "configured but unreachable LiveKit fails call capabilities closed", %{conn: conn} do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    values = %{
      audio_provider_mode: "livekit",
      livekit_server_url: "ws://127.0.0.1:#{port}",
      livekit_api_url: "http://127.0.0.1:#{port}",
      livekit_api_key: "configured-test-key",
      livekit_api_secret: "configured-test-secret",
      audio_token_ttl_seconds: 300
    }

    previous =
      Map.new(values, fn {key, _value} -> {key, Application.get_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_integrations, key),
          else: Application.put_env(:comms_integrations, key, value)
      end)

      LiveKitReadiness.refresh()
    end)

    assert :ok = LiveKitReadiness.refresh()

    assert eventually(fn ->
             LiveKitReadiness.status() == %{
               status: :unavailable,
               adapter: :livekit,
               reason: :provider_unreachable
             }
           end)

    response =
      conn
      |> get("/api/v1/status")
      |> json_response(200)

    assert response["capabilities"]["audio_calls"] == false
    assert response["capabilities"]["video_calls"] == false
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

  defp eventually(fun, attempts \\ 80)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp restore_env(key, nil), do: Application.delete_env(:comms_core, key)
  defp restore_env(key, value), do: Application.put_env(:comms_core, key, value)
end
