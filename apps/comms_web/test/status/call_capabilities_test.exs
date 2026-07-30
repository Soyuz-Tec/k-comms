defmodule CommsWeb.Status.CallCapabilitiesTest do
  use CommsWeb.StatusCase

  alias CommsCore.Administration.Tenant
  alias CommsCore.Repo
  alias CommsIntegrations.Audio.LiveKitReadiness
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :operations
  @moduletag :call

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
end
