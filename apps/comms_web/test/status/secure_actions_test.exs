defmodule CommsWeb.Status.SecureActionsTest do
  use CommsWeb.StatusCase

  @moduletag :integration
  @moduletag :operations
  @moduletag :release

  test "LAN release reports secure account and media actions unavailable on every HTTP host" do
    previous = Application.get_env(:comms_web, :insecure_lan_release)
    Application.put_env(:comms_web, :insecure_lan_release, true)

    on_exit(fn ->
      restore_env(:comms_web, :insecure_lan_release, previous)
    end)

    for host <- ["127.0.0.1", "localhost", "192.168.1.177"] do
      capabilities =
        build_conn()
        |> Map.put(:host, host)
        |> get("/api/v1/status")
        |> json_response(200)
        |> Map.fetch!("capabilities")

      assert capabilities["secure_account_actions"] == false
      assert capabilities["secure_media_actions"] == false
    end
  end

  test "secure actions remain available for normal development HTTP and HTTPS" do
    previous = Application.get_env(:comms_web, :insecure_lan_release)

    on_exit(fn ->
      restore_env(:comms_web, :insecure_lan_release, previous)
    end)

    Application.put_env(:comms_web, :insecure_lan_release, false)

    development_capabilities =
      build_conn()
      |> Map.put(:host, "127.0.0.1")
      |> get("/api/v1/status")
      |> json_response(200)
      |> Map.fetch!("capabilities")

    assert development_capabilities["secure_account_actions"] == true
    assert development_capabilities["secure_media_actions"] == true

    Application.put_env(:comms_web, :insecure_lan_release, true)

    https_capabilities =
      build_conn()
      |> get("https://comms.example.test/api/v1/status")
      |> json_response(200)
      |> Map.fetch!("capabilities")

    assert https_capabilities["secure_account_actions"] == true
    assert https_capabilities["secure_media_actions"] == true
  end

  test "trusted-edge status is secure only after the trusted proxy establishes HTTPS" do
    values = %{
      insecure_lan_release: false,
      secure_transport_required: true,
      trusted_proxy_cidrs: ["10.89.0.12/32"],
      hsts: true
    }

    previous =
      Map.new(values, fn {key, _value} -> {key, Application.get_env(:comms_web, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_web, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        restore_env(:comms_web, key, value)
      end)
    end)

    direct_capabilities =
      build_conn()
      |> Map.put(:remote_ip, {10, 89, 0, 12})
      |> get("/api/v1/status")
      |> json_response(200)
      |> Map.fetch!("capabilities")

    assert direct_capabilities["secure_account_actions"] == false
    assert direct_capabilities["secure_media_actions"] == false

    trusted_response =
      build_conn()
      |> Map.put(:remote_ip, {10, 89, 0, 12})
      |> put_req_header("x-forwarded-proto", "https")
      |> get("/api/v1/status")

    trusted_capabilities =
      trusted_response
      |> json_response(200)
      |> Map.fetch!("capabilities")

    assert trusted_capabilities["secure_account_actions"] == true
    assert trusted_capabilities["secure_media_actions"] == true

    assert get_resp_header(trusted_response, "strict-transport-security") == [
             "max-age=31536000; includeSubDomains"
           ]
  end
end
