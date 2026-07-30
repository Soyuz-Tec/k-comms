defmodule CommsWeb.GuestCommunicationTestSupport.RoomService do
  @moduledoc false

  def delete_room(provider_room) when is_binary(provider_room) do
    send(Application.fetch_env!(:comms_integrations, :guest_room_service_test_pid), {
      :delete_guest_room,
      provider_room
    })

    :ok
  end
end

defmodule CommsWeb.GuestCommunicationMediaTestSupport do
  @moduledoc false

  import ExUnit.Assertions

  alias CommsIntegrations.Audio.LiveKitReadiness

  def setup_livekit(_context) do
    {provider_socket, provider_port} = start_readiness_endpoint()

    provider_config = %{
      audio_provider_mode: "livekit",
      livekit_server_url: "wss://guest-media.example.test",
      livekit_api_url: "http://127.0.0.1:#{provider_port}",
      livekit_api_key: "guest-test-api-key",
      livekit_api_secret: "guest-test-api-secret",
      audio_token_ttl_seconds: 300,
      audio_room_service_adapter: CommsWeb.GuestCommunicationTestSupport.RoomService,
      guest_room_service_test_pid: self()
    }

    previous_provider_config =
      Map.new(provider_config, fn {key, _value} ->
        {key, Application.get_env(:comms_integrations, key)}
      end)

    Enum.each(provider_config, fn {key, value} ->
      Application.put_env(:comms_integrations, key, value)
    end)

    assert :ok = LiveKitReadiness.refresh()
    assert eventually(fn -> LiveKitReadiness.ensure_available() == :ok end)

    ExUnit.Callbacks.on_exit(fn ->
      :ok = :gen_tcp.close(provider_socket)

      Enum.each(previous_provider_config, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_integrations, key),
          else: Application.put_env(:comms_integrations, key, value)
      end)

      LiveKitReadiness.refresh()
    end)

    :ok
  end

  defp start_readiness_endpoint do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    spawn_link(fn -> serve_readiness(listener) end)
    {listener, port}
  end

  defp serve_readiness(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 12\r\nconnection: close\r\n\r\n{\"rooms\":[]}"
          )

        :gen_tcp.close(socket)
        serve_readiness(listener)

      {:error, :closed} ->
        :ok
    end
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
end
