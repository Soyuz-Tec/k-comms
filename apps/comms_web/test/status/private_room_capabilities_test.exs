defmodule CommsWeb.Status.PrivateRoomCapabilitiesTest do
  use CommsWeb.StatusCase

  @moduletag :integration
  @moduletag :operations

  setup do
    keys = [
      :private_rooms_enabled,
      :matrix_client_provisioning_enabled,
      :matrix_identity_provider,
      :matrix_provisioning_adapter,
      :private_room_control_adapter
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:comms_core, &1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    Application.put_env(:comms_core, :private_rooms_enabled, true)
    Application.put_env(:comms_core, :matrix_client_provisioning_enabled, true)

    Application.put_env(:comms_core, :matrix_identity_provider, %{
      issuer: "https://matrix.example.test",
      server_name: "matrix.example.test",
      control_user_id: "@control:matrix.example.test"
    })

    :ok
  end

  test "configuration preflight requires both deployment switches", %{conn: conn} do
    assert capability(conn)

    for key <- [:private_rooms_enabled, :matrix_client_provisioning_enabled] do
      Application.put_env(:comms_core, key, false)
      refute capability(conn)
      Application.put_env(:comms_core, key, true)
    end
  end

  test "unknown or invalid provider configuration fails closed", %{conn: conn} do
    for provider <- [
          nil,
          %{},
          %{issuer: nil, server_name: "matrix.example.test", control_user_id: "@control:test"},
          %{
            issuer: "http://matrix.example.test",
            server_name: "matrix.example.test",
            control_user_id: "@control:matrix.example.test"
          },
          %{
            issuer: "https://matrix.example.test/untrusted-path",
            server_name: "matrix.example.test",
            control_user_id: "@control:matrix.example.test"
          }
        ] do
      Application.put_env(:comms_core, :matrix_identity_provider, provider)
      refute capability(conn)
    end
  end

  test "missing provisioning or room-control adapters fail closed", %{conn: conn} do
    for key <- [:matrix_provisioning_adapter, :private_room_control_adapter] do
      previous = Application.get_env(:comms_core, key)
      Application.put_env(:comms_core, key, __MODULE__)
      refute capability(conn)
      Application.put_env(:comms_core, key, previous)
    end
  end

  test "preflight performs no enrollment and exposes no provider configuration", %{conn: conn} do
    body = conn |> get("/api/v1/status") |> json_response(200)
    assert body["capabilities"]["private_rooms"] == true
    refute Jason.encode!(body) =~ "matrix.example.test"
    # The synthetic origin cannot be contacted: success is solely configuration
    # preflight and must not be presented as live Matrix provider qualification.
  end

  test "known insecure LAN transport disables setup even when configured", %{conn: conn} do
    previous = Application.get_env(:comms_web, :insecure_lan_release)
    Application.put_env(:comms_web, :insecure_lan_release, true)
    on_exit(fn -> restore_env(:comms_web, :insecure_lan_release, previous) end)

    refute capability(conn)

    assert conn
           |> get("https://comms.example.test/api/v1/status")
           |> json_response(200)
           |> get_in(["capabilities", "private_rooms"])
  end

  defp capability(conn) do
    conn
    |> get("/api/v1/status")
    |> json_response(200)
    |> get_in(["capabilities", "private_rooms"])
  end
end
