defmodule CommsWeb.TrustedProxyTest do
  use ExUnit.Case, async: false

  alias CommsWeb.Plugs.TrustedProxy

  setup do
    previous = Application.get_env(:comms_web, :trusted_proxy_cidrs)
    Application.put_env(:comms_web, :trusted_proxy_cidrs, ["10.0.0.0/8", "fd00::/8"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_web, :trusted_proxy_cidrs, previous),
        else: Application.delete_env(:comms_web, :trusted_proxy_cidrs)
    end)
  end

  test "ignores spoofed forwarding headers from untrusted peers" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {198, 51, 100, 20})
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9")
      |> TrustedProxy.call([])

    assert conn.remote_ip == {198, 51, 100, 20}
  end

  test "selects the right-most untrusted client from a trusted proxy chain" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {10, 20, 0, 4})
      |> Plug.Conn.put_req_header(
        "x-forwarded-for",
        "192.0.2.8, 203.0.113.9, 10.30.0.7"
      )
      |> TrustedProxy.call([])

    assert conn.remote_ip == {203, 0, 113, 9}
  end

  test "supports trusted IPv6 proxy networks and fails closed on malformed chains" do
    trusted =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {0xFD00, 0, 0, 0, 0, 0, 0, 1})
      |> Plug.Conn.put_req_header("x-forwarded-for", "2001:db8::42")
      |> TrustedProxy.call([])

    assert trusted.remote_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x42}

    malformed =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {10, 20, 0, 4})
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9, invalid")
      |> TrustedProxy.call([])

    assert malformed.remote_ip == {10, 20, 0, 4}
  end

  test "accepts exactly one HTTPS forwarding value from a trusted peer" do
    conn =
      Plug.Test.conn(:get, "http://comms.avayaworks.com/api/v1/status")
      |> Map.put(:remote_ip, {10, 20, 0, 4})
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> TrustedProxy.call([])

    assert conn.scheme == :https
  end

  test "does not accept forwarded scheme from an untrusted peer" do
    conn =
      Plug.Test.conn(:get, "http://comms.avayaworks.com/api/v1/status")
      |> Map.put(:remote_ip, {198, 51, 100, 20})
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> TrustedProxy.call([])

    assert conn.scheme == :http
  end

  test "duplicate, comma-joined, and malformed forwarded schemes fail closed" do
    base =
      Plug.Test.conn(:get, "http://comms.avayaworks.com/api/v1/status")
      |> Map.put(:remote_ip, {10, 20, 0, 4})

    duplicate =
      %{base | req_headers: [{"x-forwarded-proto", "https"}, {"x-forwarded-proto", "https"}]}
      |> TrustedProxy.call([])

    assert duplicate.scheme == :http

    for value <- ["https,https", "https, http", "http", "HTTPS", " https", "https "] do
      conn =
        base
        |> Plug.Conn.put_req_header("x-forwarded-proto", value)
        |> TrustedProxy.call([])

      assert conn.scheme == :http
    end
  end
end
