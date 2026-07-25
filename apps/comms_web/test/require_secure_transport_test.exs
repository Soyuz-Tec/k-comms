defmodule CommsWeb.RequireSecureTransportTest do
  use CommsWeb.ConnCase, async: false

  import Plug.Test

  alias CommsWeb.Plugs.RequireSecureTransport

  setup do
    previous = Application.get_env(:comms_web, :insecure_lan_release)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:comms_web, :insecure_lan_release),
        else: Application.put_env(:comms_web, :insecure_lan_release, previous)
    end)
  end

  test "blocks credential and media operations in clear-text LAN mode" do
    Application.put_env(:comms_web, :insecure_lan_release, true)

    conn =
      conn(:post, "/api/v1/sessions")
      |> RequireSecureTransport.call([])

    assert conn.halted
    assert conn.status == 426

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "secure_transport_required",
               "detail" => "This operation requires a trusted HTTPS connection"
             }
           }
  end

  test "allows the operation outside clear-text LAN mode" do
    Application.put_env(:comms_web, :insecure_lan_release, false)

    conn =
      conn(:post, "/api/v1/sessions")
      |> RequireSecureTransport.call([])

    refute conn.halted
    assert conn.status == nil
  end

  test "blocks all HTTP in LAN mode without trusting Origin or a loopback Host" do
    Application.put_env(:comms_web, :insecure_lan_release, true)

    loopback =
      conn(:post, "http://127.0.0.1:4188/api/v1/sessions")
      |> RequireSecureTransport.call([])

    assert loopback.halted
    assert loopback.status == 426

    spoofed_origin =
      conn(:post, "http://192.168.1.177:4188/api/v1/sessions")
      |> put_req_header("origin", "https://comms.internal.test")
      |> RequireSecureTransport.call([])

    assert spoofed_origin.halted
    assert spoofed_origin.status == 426

    spoofed_host =
      conn(:post, "http://127.0.0.1:4188/api/v1/sessions")
      |> Map.put(:remote_ip, {192, 168, 1, 50})
      |> RequireSecureTransport.call([])

    assert spoofed_host.halted
    assert spoofed_host.status == 426
  end

  test "keeps actual HTTPS operations available" do
    Application.put_env(:comms_web, :insecure_lan_release, true)

    https =
      conn(:post, "https://comms.internal.test/api/v1/sessions")
      |> RequireSecureTransport.call([])

    refute https.halted
  end

  test "authentication routes apply the guard before reading credentials" do
    Application.put_env(:comms_web, :insecure_lan_release, true)

    response =
      build_conn()
      |> post("/api/v1/sessions", %{
        tenant_slug: "must-not-be-read",
        email: "must-not-be-read@example.test",
        password: "must-not-be-read"
      })

    assert json_response(response, 426)["error"]["code"] ==
             "secure_transport_required"
  end

  test "authentication routes reject a spoofed loopback host from a LAN peer" do
    Application.put_env(:comms_web, :insecure_lan_release, true)

    response =
      build_conn()
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:remote_ip, {192, 168, 1, 50})
      |> post("/api/v1/sessions", %{
        tenant_slug: "must-not-be-read",
        email: "must-not-be-read@example.test",
        password: "must-not-be-read"
      })

    assert json_response(response, 426)["error"]["code"] ==
             "secure_transport_required"
  end
end
