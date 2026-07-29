defmodule CommsIntegrations.Audio.IceServersTest do
  use ExUnit.Case, async: false

  alias CommsIntegrations.Audio.IceServers

  @keys [
    :stun_urls,
    :turn_urls,
    :turn_static_auth_secret,
    :turn_credential_ttl_seconds,
    :allow_insecure_local_media
  ]

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:comms_integrations, &1)})

    Enum.each(@keys, &Application.delete_env(:comms_integrations, &1))
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

  describe "when no relay is configured" do
    test "returns an empty list rather than an error" do
      assert {:ok, []} = IceServers.for_participant("participant-1")
    end

    test "reports unconfigured status" do
      assert %{status: :unconfigured, relay: false} = IceServers.status()
    end
  end

  describe "STUN only" do
    test "returns the STUN servers without credentials" do
      Application.put_env(:comms_integrations, :stun_urls, ["stun:stun.example.test:3478"])

      assert {:ok, [%{urls: ["stun:stun.example.test:3478"]} = server]} =
               IceServers.for_participant("participant-1")

      refute Map.has_key?(server, :username)
      refute Map.has_key?(server, :credential)
    end
  end

  describe "TURN relay" do
    setup do
      Application.put_env(:comms_integrations, :turn_urls, ["turns:relay.example.test:5349"])

      Application.put_env(
        :comms_integrations,
        :turn_static_auth_secret,
        "a-sufficiently-long-secret"
      )

      :ok
    end

    test "derives a coturn REST credential bound to the participant and an expiry" do
      assert {:ok,
              [
                %{
                  urls: ["turns:relay.example.test:5349"],
                  username: username,
                  credential: credential
                }
              ]} =
               IceServers.for_participant("participant-1")

      assert [expiry, "participant-1"] = String.split(username, ":", parts: 2)
      assert {expiry, ""} = Integer.parse(expiry)
      assert expiry > System.system_time(:second)

      expected =
        :hmac
        |> :crypto.mac(:sha, "a-sufficiently-long-secret", username)
        |> Base.encode64()

      assert credential == expected
    end

    test "issues a distinct credential per participant" do
      assert {:ok, [%{username: first}]} = IceServers.for_participant("participant-1")
      assert {:ok, [%{username: second}]} = IceServers.for_participant("participant-2")

      refute first == second
    end

    test "places STUN before the relay when both are configured" do
      Application.put_env(:comms_integrations, :stun_urls, ["stun:stun.example.test:3478"])

      assert {:ok, [stun, relay]} = IceServers.for_participant("participant-1")
      assert stun == %{urls: ["stun:stun.example.test:3478"]}
      assert Map.has_key?(relay, :credential)
    end

    test "rejects a relay configured without a secret" do
      Application.delete_env(:comms_integrations, :turn_static_auth_secret)

      assert {:error, :turn_static_auth_secret_missing} =
               IceServers.for_participant("participant-1")
    end

    test "rejects a secret too short to be meaningful" do
      Application.put_env(:comms_integrations, :turn_static_auth_secret, "short")

      assert {:error, :turn_static_auth_secret_too_short} =
               IceServers.for_participant("participant-1")
    end

    test "rejects a credential lifetime outside the permitted range" do
      Application.put_env(:comms_integrations, :turn_credential_ttl_seconds, 10)

      assert {:error, :turn_credential_ttl_invalid} = IceServers.for_participant("participant-1")
    end
  end

  describe "transport security" do
    setup do
      Application.put_env(
        :comms_integrations,
        :turn_static_auth_secret,
        "a-sufficiently-long-secret"
      )

      :ok
    end

    test "refuses a plaintext turn: relay in a promoted environment" do
      Application.put_env(:comms_integrations, :turn_urls, ["turn:relay.example.test:3478"])

      assert {:error, :insecure_turn_endpoint} = IceServers.for_participant("participant-1")
    end

    test "permits a plaintext turn: relay only behind the local-development gate" do
      Application.put_env(:comms_integrations, :turn_urls, ["turn:relay.example.test:3478"])
      Application.put_env(:comms_integrations, :allow_insecure_local_media, true)

      assert {:ok, [%{urls: ["turn:relay.example.test:3478"]}]} =
               IceServers.for_participant("participant-1")
    end

    test "permits plaintext stun: without the gate because it carries no credential" do
      Application.put_env(:comms_integrations, :stun_urls, ["stun:stun.example.test:3478"])
      Application.delete_env(:comms_integrations, :turn_urls)

      assert {:ok, [%{urls: ["stun:stun.example.test:3478"]}]} =
               IceServers.for_participant("participant-1")
    end

    test "rejects a non-ICE scheme" do
      Application.put_env(:comms_integrations, :turn_urls, ["https://relay.example.test"])

      assert {:error, :ice_server_scheme_invalid} = IceServers.for_participant("participant-1")
    end

    test "rejects a STUN entry carrying a turn: scheme" do
      Application.put_env(:comms_integrations, :stun_urls, ["turns:relay.example.test:5349"])

      assert {:error, :ice_server_scheme_invalid} = IceServers.for_participant("participant-1")
    end

    test "accepts a transport query suffix" do
      Application.put_env(
        :comms_integrations,
        :turn_urls,
        ["turns:relay.example.test:5349?transport=tcp"]
      )

      assert {:ok, [%{urls: ["turns:relay.example.test:5349?transport=tcp"]}]} =
               IceServers.for_participant("participant-1")
    end
  end

  test "rejects a blank participant identity" do
    assert {:error, :audio_identity_invalid} = IceServers.for_participant("")
  end
end
