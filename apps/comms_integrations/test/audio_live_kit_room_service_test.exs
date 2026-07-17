defmodule CommsIntegrations.Audio.LiveKitRoomServiceTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.Audio.LiveKitRoomService

  setup do
    values = %{
      audio_provider_mode: "livekit",
      livekit_server_url: "wss://audio.example.test",
      livekit_api_url: "https://audio-api.example.test",
      livekit_api_key: "test-api-key",
      livekit_api_secret: "test-api-secret",
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
    end)

    :ok
  end

  test "deletes the exact server-derived room with a short room-control credential" do
    parent = self()

    requester = fn request ->
      send(parent, {:request, request})
      {:ok, %Finch.Response{status: 200, body: "{}"}}
    end

    assert :ok =
             LiveKitRoomService.delete_room(%{provider_room: "kc_audio_exact_room"}, requester)

    assert_receive {:request, request}
    assert request.method == "POST"
    assert request.scheme == :https
    assert request.host == "audio-api.example.test"
    assert request.path == "/twirp/livekit.RoomService/DeleteRoom"
    assert Jason.decode!(request.body) == %{"room" => "kc_audio_exact_room"}

    {"authorization", "Bearer " <> token} =
      Enum.find(request.headers, fn {name, _value} -> name == "authorization" end)

    [_header, encoded_claims, _signature] = String.split(token, ".")
    claims = encoded_claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["exp"] - claims["nbf"] <= 35
    assert claims["video"] == %{"roomCreate" => true}
    refute Map.has_key?(claims, "sub")
    refute Map.has_key?(claims["video"], "roomRecord")
  end

  test "not-found deletion is idempotent and provider failures fail closed" do
    call = %{provider_room: "kc_audio_missing_room"}

    assert :ok =
             LiveKitRoomService.delete_room(call, fn _request ->
               {:ok, %Finch.Response{status: 404, body: ""}}
             end)

    assert :ok =
             LiveKitRoomService.delete_room(call, fn _request ->
               {:ok, %Finch.Response{status: 400, body: Jason.encode!(%{code: "not_found"})}}
             end)

    assert {:error, :audio_provider_unavailable} =
             LiveKitRoomService.delete_room(call, fn _request -> {:error, :timeout} end)
  end

  test "removes one exact participant with a short exact-room admin credential" do
    parent = self()

    requester = fn request ->
      send(parent, {:remove_request, request})
      {:ok, %Finch.Response{status: 200, body: "{}"}}
    end

    assert :ok =
             LiveKitRoomService.remove_participant(
               %{provider_room: "kc_audio_exact_room"},
               "kc_exact_participant_identity",
               requester
             )

    assert_receive {:remove_request, request}
    assert request.method == "POST"
    assert request.path == "/twirp/livekit.RoomService/RemoveParticipant"

    assert Jason.decode!(request.body) == %{
             "room" => "kc_audio_exact_room",
             "identity" => "kc_exact_participant_identity"
           }

    {"authorization", "Bearer " <> token} =
      Enum.find(request.headers, fn {name, _value} -> name == "authorization" end)

    [_header, encoded_claims, _signature] = String.split(token, ".")
    claims = encoded_claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["exp"] - claims["nbf"] <= 35

    assert claims["video"] == %{
             "room" => "kc_audio_exact_room",
             "roomAdmin" => true
           }

    refute Map.has_key?(claims, "sub")

    assert :ok =
             LiveKitRoomService.remove_participant(
               %{provider_room: "kc_audio_exact_room"},
               "kc_exact_participant_identity",
               fn _request -> {:ok, %Finch.Response{status: 404, body: ""}} end
             )
  end
end
