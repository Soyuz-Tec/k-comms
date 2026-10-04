defmodule CommsIntegrations.Telephony.ConfigTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.Telephony.Config

  test "optional telephony remains disabled without any provider credentials" do
    assert Config.validate!(mode: "disabled") == %{enabled: false}
    assert {:error, :telephony_provider_mode} = Config.configuration(mode: "unexpected")
  end

  test "enabled SIP requires coherent secure media credentials and bounded timers" do
    assert %{enabled: true, ring_timeout_seconds: 45} = Config.validate!(options())
    assert {:error, :audio_provider_mode} = Config.configuration(options(audio_mode: "disabled"))

    assert {:error, :livekit_api_url} =
             Config.configuration(options(api_url: "http://media.example.test"))

    assert {:error, :livekit_api_url} =
             Config.configuration(options(api_url: "https://media.example.test/path"))

    assert {:error, :livekit_api_url} =
             Config.configuration(options(api_url: "https://user:pass@media.example.test"))

    assert {:error, :livekit_api_url} =
             Config.configuration(options(api_url: "https://127.0.0.1"))

    assert {:error, :livekit_server_url} =
             Config.configuration(options(server_url: "wss://example.invalid"))

    assert {:error, :telephony_ring_timeout_seconds} =
             Config.configuration(options(ring_timeout_seconds: 91))

    assert {:error, :telephony_max_duration_seconds} =
             Config.configuration(options(max_duration_seconds: 59))
  end

  test "plaintext media is restricted to explicitly gated loopback fixtures" do
    local = [server_url: "ws://127.0.0.1:7880", api_url: "http://127.0.0.1:7880"]
    assert {:error, :livekit_server_url} = Config.configuration(options(local))

    assert %{enabled: true} =
             Config.validate!(options(local ++ [allow_insecure_local_media: true]))

    assert {:error, :livekit_api_url} =
             Config.configuration(
               options(api_url: "http://livekit:7880", allow_insecure_local_media: true)
             )

    assert {:error, :livekit_server_url} =
             Config.configuration(options(local ++ [allow_insecure_local_media: "true"]))
  end

  test "configuration errors never contain secrets" do
    secret = "private-credential-do-not-disclose"

    error =
      assert_raise ArgumentError, fn ->
        Config.validate!(options(api_secret: secret, api_url: "http://media.example.test"))
      end

    refute Exception.message(error) =~ secret
  end

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        mode: "livekit",
        audio_mode: "livekit",
        server_url: "wss://media.example.test",
        api_url: "https://media.example.test",
        api_key: "synthetic-api-key",
        api_secret: "synthetic-livekit-secret-minimum-32-bytes",
        ring_timeout_seconds: 45,
        max_duration_seconds: 1_800,
        allow_insecure_local_media: false
      ],
      overrides
    )
  end
end
