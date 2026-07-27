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
      :audio_token_ttl_seconds,
      :allow_insecure_local_media
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:comms_integrations, &1)})

    Application.put_env(:comms_integrations, :audio_provider_mode, "livekit")
    Application.put_env(:comms_integrations, :livekit_server_url, "wss://audio.example.test")
    Application.put_env(:comms_integrations, :livekit_api_url, "https://audio-api.example.test")
    Application.put_env(:comms_integrations, :livekit_api_key, "test-api-key")
    Application.put_env(:comms_integrations, :livekit_api_secret, "test-api-secret")
    Application.put_env(:comms_integrations, :audio_token_ttl_seconds, 300)
    Application.put_env(:comms_integrations, :allow_insecure_local_media, false)

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
    assert {:ok, credential} =
             LiveKitToken.issue(
               "kc_audio_exact_room",
               :audio,
               "kc_exact_stored_provider_identity",
               "Audio Member"
             )

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
    assert {:ok, credential} =
             LiveKitToken.issue(
               "kc_video_exact_room",
               :video,
               "kc_video_provider_identity",
               "Video Member"
             )

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

  test "caps a guest participant token at the exact authorization deadline" do
    deadline = DateTime.utc_now() |> DateTime.add(30, :second)
    issued_at = System.system_time(:second)

    assert {:ok, credential} =
             LiveKitToken.issue(
               "kc_guest_exact_room",
               :video,
               "kc_guest_provider_identity",
               "Guest Member",
               deadline
             )

    [_header, encoded_claims, _signature] = String.split(credential.participant_token, ".")
    claims = decode(encoded_claims)

    assert credential.expires_in in 29..30
    assert (claims["exp"] - credential.expires_in) in issued_at..System.system_time(:second)
    assert claims["exp"] <= DateTime.to_unix(deadline, :second)
  end

  test "fails closed when guest authority has no remaining whole-second lifetime" do
    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second)

    assert {:error, :call_authorization_expired} =
             LiveKitToken.issue(
               "kc_guest_expired_room",
               :audio,
               "kc_guest_expired_identity",
               "Expired Guest",
               expired_at
             )
  end

  test "fails closed for disabled, overlong TTL, or non-origin provider URLs" do
    input = ["kc_audio_room", :audio, "kc_test_provider_identity", "A"]

    Application.put_env(:comms_integrations, :audio_provider_mode, "disabled")

    assert apply(LiveKitToken, :issue, input) ==
             {:error, :audio_provider_unavailable}

    Application.put_env(:comms_integrations, :audio_provider_mode, "livekit")
    Application.put_env(:comms_integrations, :audio_token_ttl_seconds, 301)

    assert apply(LiveKitToken, :issue, input) ==
             {:error, :audio_provider_unavailable}

    Application.put_env(:comms_integrations, :audio_token_ttl_seconds, 300)
    Application.put_env(:comms_integrations, :livekit_server_url, "wss://audio.example.test/path")
    assert LiveKitToken.ensure_available() == {:error, :audio_provider_unavailable}
  end

  test "refuses to issue any credential over a plaintext media origin by default" do
    input = [
      "kc_audio_exact_room",
      :audio,
      "kc_exact_stored_provider_identity",
      "Audio Member"
    ]

    # A participant token hands this URL to the browser. Without the explicit
    # local-development gate, a plaintext signalling origin must fail closed
    # rather than downgrade the media transport.
    Application.put_env(:comms_integrations, :livekit_server_url, "ws://audio.example.test")

    assert apply(LiveKitToken, :issue, input) == {:error, :audio_provider_unavailable}
    assert LiveKitToken.ensure_available() == {:error, :audio_provider_unavailable}

    Application.put_env(:comms_integrations, :livekit_server_url, "wss://audio.example.test")

    # The room-control and room-admin tokens are admin-scoped, so a plaintext
    # SFU control origin must fail closed on the same gate.
    Application.put_env(:comms_integrations, :livekit_api_url, "http://audio-api.example.test")

    assert apply(LiveKitToken, :issue, input) == {:error, :audio_provider_unavailable}

    assert LiveKitToken.issue_room_control("kc_audio_exact_room") ==
             {:error, :audio_provider_unavailable}

    assert LiveKitToken.issue_room_admin("kc_audio_exact_room") ==
             {:error, :audio_provider_unavailable}

    assert LiveKitToken.issue_readiness() == {:error, :audio_provider_unavailable}
  end

  test "permits plaintext media origins only behind the explicit local gate" do
    input = [
      "kc_audio_exact_room",
      :audio,
      "kc_exact_stored_provider_identity",
      "Audio Member"
    ]

    Application.put_env(:comms_integrations, :livekit_server_url, "ws://127.0.0.1:7880")
    Application.put_env(:comms_integrations, :livekit_api_url, "http://livekit:7880")

    assert apply(LiveKitToken, :issue, input) == {:error, :audio_provider_unavailable}

    Application.put_env(:comms_integrations, :allow_insecure_local_media, true)

    assert {:ok, credential} = apply(LiveKitToken, :issue, input)
    assert credential.server_url == "ws://127.0.0.1:7880"
    assert {:ok, _control} = LiveKitToken.issue_room_control("kc_audio_exact_room")

    # Only an exact boolean opt-in counts; a truthy value must not open the gate.
    Application.put_env(:comms_integrations, :allow_insecure_local_media, "true")

    assert apply(LiveKitToken, :issue, input) == {:error, :audio_provider_unavailable}
  end

  defp decode(value) do
    value |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end
end
