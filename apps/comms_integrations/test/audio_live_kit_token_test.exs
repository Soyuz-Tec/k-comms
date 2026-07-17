defmodule CommsIntegrations.Audio.LiveKitTokenTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.Audio.LiveKitToken

  setup do
    keys = [
      :audio_provider_mode,
      :livekit_server_url,
      :livekit_api_url,
      :livekit_api_key,
      :livekit_api_secret,
      :audio_token_ttl_seconds
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:comms_integrations, &1)})

    Application.put_env(:comms_integrations, :audio_provider_mode, "livekit")
    Application.put_env(:comms_integrations, :livekit_server_url, "wss://audio.example.test")
    Application.put_env(:comms_integrations, :livekit_api_url, "https://audio-api.example.test")
    Application.put_env(:comms_integrations, :livekit_api_key, "test-api-key")
    Application.put_env(:comms_integrations, :livekit_api_secret, "test-api-secret")
    Application.put_env(:comms_integrations, :audio_token_ttl_seconds, 300)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_integrations, key),
          else: Application.put_env(:comms_integrations, key, value)
      end)
    end)

    :ok
  end

  test "signs an opaque, call-bound, microphone-only LiveKit grant" do
    call = %{id: "call-1", provider_room: "kc_audio_exact_room", media_kind: :audio}

    participant = %{provider_identity: "kc_exact_stored_provider_identity"}

    assert {:ok, credential} =
             LiveKitToken.issue(call, participant, %{display_name: "Audio Member"})

    assert credential.server_url == "wss://audio.example.test"
    assert credential.expires_in == 300

    [encoded_header, encoded_claims, encoded_signature] =
      String.split(credential.participant_token, ".")

    header = decode(encoded_header)
    claims = decode(encoded_claims)
    assert header == %{"alg" => "HS256", "typ" => "JWT"}
    assert claims["iss"] == "test-api-key"
    assert claims["name"] == "Audio Member"
    assert claims["exp"] - claims["nbf"] <= 305

    assert claims["video"] == %{
             "canPublish" => true,
             "canPublishData" => false,
             "canPublishSources" => ["microphone"],
             "canSubscribe" => true,
             "canUpdateOwnMetadata" => false,
             "room" => "kc_audio_exact_room",
             "roomAdmin" => false,
             "roomJoin" => true,
             "roomRecord" => false
           }

    assert claims["sub"] == "kc_exact_stored_provider_identity"

    expected =
      :crypto.mac(
        :hmac,
        :sha256,
        "test-api-secret",
        encoded_header <> "." <> encoded_claims
      )
      |> Base.url_encode64(padding: false)

    assert encoded_signature == expected
  end

  test "video calls grant only microphone, camera, and screen publishing" do
    call = %{id: "call-2", provider_room: "kc_video_exact_room", media_kind: :video}
    participant = %{provider_identity: "kc_video_provider_identity"}

    assert {:ok, credential} =
             LiveKitToken.issue(call, participant, %{display_name: "Video Member"})

    [_header, encoded_claims, _signature] = String.split(credential.participant_token, ".")
    claims = decode(encoded_claims)

    assert claims["video"] == %{
             "canPublish" => true,
             "canPublishData" => false,
             "canPublishSources" => [
               "microphone",
               "camera",
               "screen_share",
               "screen_share_audio"
             ],
             "canSubscribe" => true,
             "canUpdateOwnMetadata" => false,
             "room" => "kc_video_exact_room",
             "roomAdmin" => false,
             "roomJoin" => true,
             "roomRecord" => false
           }
  end

  test "fails closed for disabled, overlong TTL, or non-origin provider URLs" do
    input =
      {%{id: "call-1", provider_room: "kc_audio_room"},
       %{provider_identity: "kc_test_provider_identity"}, %{display_name: "A"}}

    Application.put_env(:comms_integrations, :audio_provider_mode, "disabled")

    assert apply(LiveKitToken, :issue, Tuple.to_list(input)) ==
             {:error, :audio_provider_unavailable}

    Application.put_env(:comms_integrations, :audio_provider_mode, "livekit")
    Application.put_env(:comms_integrations, :audio_token_ttl_seconds, 301)

    assert apply(LiveKitToken, :issue, Tuple.to_list(input)) ==
             {:error, :audio_provider_unavailable}

    Application.put_env(:comms_integrations, :audio_token_ttl_seconds, 300)
    Application.put_env(:comms_integrations, :livekit_server_url, "wss://audio.example.test/path")
    assert LiveKitToken.ensure_available() == {:error, :audio_provider_unavailable}
  end

  defp decode(value) do
    value |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end
end
