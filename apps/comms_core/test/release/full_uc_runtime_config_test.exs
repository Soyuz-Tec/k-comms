defmodule CommsCore.Release.FullUCRuntimeConfigTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :release
  @variables ~w(IDENTITY_SECRET_ENCRYPTION_KEY IDENTITY_SECRET_ENCRYPTION_KEY_ID IDENTITY_SECRET_ENCRYPTION_KEYS IDENTITY_SECRET_ENCRYPTION_KEYS_JSON IDENTITY_SECRET_ENCRYPTION_KEY_FILE IDENTITY_SECRET_ENCRYPTION_KEYS_FILE IDENTITY_SECRET_ENCRYPTION_KEYS_JSON_FILE IDENTITY_BREAK_GLASS_SECRET IDENTITY_BREAK_GLASS_SECRET_FILE OIDC_ENABLED OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_CLIENT_SECRET_FILE OIDC_REDIRECT_URI OIDC_ALLOWED_REDIRECT_URIS_JSON OIDC_REQUIRED_ACR_VALUES OIDC_SCIM_SUBJECT_MAPPING TELEPHONY_CONTROL_PROVIDER TELEPHONY_TRANSFER_ENABLED TELEPHONY_TRANSFER_DESTINATION_PREFIXES TELEPHONY_PBX_ENABLED TELEPHONY_PBX_QUALIFIED TELEPHONY_PBX_API_URL TELEPHONY_PBX_USERNAME TELEPHONY_PBX_USERNAME_FILE TELEPHONY_PBX_PASSWORD TELEPHONY_PBX_PASSWORD_FILE TELEPHONY_PBX_ENDPOINT TELEPHONY_PBX_APPLICATION TELEPHONY_PBX_DESTINATION_PREFIXES TELEPHONY_PBX_WEBHOOK_SECRET TELEPHONY_PBX_WEBHOOK_SECRET_FILE TELEPHONY_VOICEMAIL_STORAGE_QUALIFIED MEETING_ARTIFACT_PRIVACY_APPROVED MEETING_ARTIFACT_PROVIDER_QUALIFIED MEETING_ARTIFACT_ENABLED_TENANT_IDS MEETING_ARTIFACTS_ENABLED LIVEKIT_EGRESS_ENABLED ARTIFACT_TRANSCRIPTION_ENABLED ARTIFACT_TRANSCRIPTION_QUALIFIED ARTIFACT_TRANSCRIPTION_ORIGIN ARTIFACT_TRANSCRIPTION_MAX_MEDIA_BYTES ARTIFACT_TRANSCRIPTION_MAX_RESPONSE_BYTES ARTIFACT_TRANSCRIPTION_TIMEOUT_MS ARTIFACT_TRANSCRIPTION_MODEL ARTIFACT_TRANSCRIPTION_LANGUAGE DIRECT_AUDIO_P2P_ENABLED DIRECT_AUDIO_STUN_URLS PUSH_SUBSCRIPTION_ENCRYPTION_KEY PUSH_SUBSCRIPTION_ENCRYPTION_KEYS WEBHOOK_SECRET_ENCRYPTION_KEY WEBHOOK_SECRET_ENCRYPTION_KEYS AUDIO_PROVIDER_MODE TELEPHONY_PROVIDER_MODE LIVEKIT_API_URL LIVEKIT_SERVER_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET)
  setup do
    base = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/k_comms_runtime_config_test",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "K_COMMS_ROLE" => "migration-operator-role",
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_INSTANCE_ID" => "full-uc-runtime-fixture",
      "PUBLIC_APP_URL" => "https://comms.example.test",
      "PASSWORD_RECOVERY_SIGNING_KEY" => String.duplicate("r", 32),
      "S3_ACCESS_KEY_ID" => "runtime-fixture-access",
      "S3_SECRET_ACCESS_KEY" => "runtime-fixture-secret"
    }

    names = Enum.uniq(@variables ++ ~w(TURN_STATIC_AUTH_SECRET TURN_URLS) ++ Map.keys(base))
    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(@variables ++ ~w(TURN_STATIC_AUTH_SECRET TURN_URLS), &System.delete_env/1)
    Enum.each(base, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "optional UC providers are disabled by default and DTMF fingerprints use a separate derived domain" do
    config = runtime()
    core = Keyword.fetch!(config, :comms_core)
    integrations = Keyword.fetch!(config, :comms_integrations)
    refute core[:oidc].enabled
    refute core[:meeting_artifact_policy][:privacy_approved]
    refute integrations[:meeting_artifacts_enabled]
    refute integrations[:egress_enabled]
    refute integrations[:telephony_pbx_enabled]
    refute integrations[:telephony_transfer_enabled]
    refute integrations[:telephony_voicemail_storage_qualified]
    refute integrations[:artifact_transcription][:enabled]
    assert core[:telephony_control_adapter] == CommsIntegrations.Telephony.LiveKit

    assert core[:telephony_control_fingerprint_key] ==
             :crypto.mac(
               :hmac,
               :sha256,
               String.duplicate("s", 64),
               "k-comms-telephony-controls-v1"
             )

    assert core[:direct_audio_p2p_enabled] ==
             Keyword.fetch!(config, :comms_web)[:direct_audio_p2p_enabled]
  end

  test "recording refuses incomplete privacy scope and direct audio P2P" do
    put(%{"MEETING_ARTIFACTS_ENABLED" => "true", "LIVEKIT_EGRESS_ENABLED" => "true"})
    assert_raise RuntimeError, ~r/require privacy approval/, fn -> runtime() end
    put(recording_scope())
    assert_raise RuntimeError, ~r/DIRECT_AUDIO_P2P_ENABLED=false/, fn -> runtime() end
    put(%{"DIRECT_AUDIO_P2P_ENABLED" => "false"})
    config = runtime()

    assert config[:comms_core][:meeting_artifact_policy][:enabled_tenant_ids] == [
             "4acf5490-60ba-439d-8a74-84960a9a1e4d"
           ]

    refute config[:comms_core][:direct_audio_p2p_enabled]
    assert config[:comms_integrations][:meeting_artifacts_enabled]
  end

  test "actual release command overrides load after media activation without changing application flags" do
    activated =
      Map.merge(recording_scope(), %{
        "MEETING_ARTIFACTS_ENABLED" => "true",
        "LIVEKIT_EGRESS_ENABLED" => "true",
        "ARTIFACT_TRANSCRIPTION_ENABLED" => "true",
        "ARTIFACT_TRANSCRIPTION_QUALIFIED" => "true",
        "ARTIFACT_TRANSCRIPTION_ORIGIN" => "https://transcription.example.test",
        "DIRECT_AUDIO_P2P_ENABLED" => "false",
        "TELEPHONY_PROVIDER_MODE" => "livekit"
      })

    put(activated)
    assert runtime()[:comms_integrations][:meeting_artifacts_enabled]

    commands =
      for relative <- ["deploy/proxmox/bin/deploy.sh", "deploy/proxmox/bin/rollback.sh"],
          [command] <-
            Regex.scan(
              ~r/--env AUDIO_PROVIDER_MODE=disabled.*?eval 'CommsCore.Release\.[^']*'/s,
              Path.expand("../../../../#{relative}", __DIR__) |> File.read!()
            ) do
        command
      end

    # Recovery, forward migration, synthetic bootstrap and explicit rollback.
    assert length(commands) == 4

    for command <- commands do
      overrides =
        Regex.scan(~r/--env ([A-Z_]+)=([^\s\\]*)/, command)
        |> Map.new(fn [_, key, value] -> {key, value} end)

      assert overrides["MEETING_ARTIFACTS_ENABLED"] == "false"
      assert overrides["LIVEKIT_EGRESS_ENABLED"] == "false"
      assert overrides["ARTIFACT_TRANSCRIPTION_ENABLED"] == "false"
      assert overrides["TELEPHONY_PROVIDER_MODE"] == "disabled"

      try do
        put(overrides)
        preflight = runtime()
        refute preflight[:comms_integrations][:meeting_artifacts_enabled]
        refute preflight[:comms_integrations][:egress_enabled]
        refute preflight[:comms_integrations][:artifact_transcription][:enabled]
        # The one-shot admission overrides cannot erase persisted tenant scope
        # or its reviewed privacy configuration used by the application.
        assert preflight[:comms_core][:meeting_artifact_policy][:privacy_approved]
      after
        put(activated)
      end

      assert Enum.all?(activated, fn {key, value} -> System.get_env(key) == value end)
      restored = runtime()
      assert restored[:comms_integrations][:meeting_artifacts_enabled]
      assert restored[:comms_integrations][:egress_enabled]
      assert restored[:comms_integrations][:artifact_transcription][:enabled]
    end
  end

  test "tenant identifiers, JSON redirects, provider modes and transcription limits are validated" do
    put(%{"MEETING_ARTIFACT_ENABLED_TENANT_IDS" => "not-a-tenant"})
    assert_raise RuntimeError, ~r/must contain tenant UUIDs/, fn -> runtime() end
    System.delete_env("MEETING_ARTIFACT_ENABLED_TENANT_IDS")
    put(%{"TELEPHONY_CONTROL_PROVIDER" => "typo-provider"})
    assert_raise RuntimeError, ~r/must be livekit or asterisk_ari/, fn -> runtime() end
    System.delete_env("TELEPHONY_CONTROL_PROVIDER")
    put(%{"OIDC_ALLOWED_REDIRECT_URIS_JSON" => "{}"})
    assert_raise RuntimeError, ~r/must be a JSON array/, fn -> runtime() end
    System.delete_env("OIDC_ALLOWED_REDIRECT_URIS_JSON")
    put(%{"ARTIFACT_TRANSCRIPTION_MAX_RESPONSE_BYTES" => "1048577"})
    assert_raise RuntimeError, ~r/between 1 and 1048576/, fn -> runtime() end
  end

  test "identity rotation keys cannot reuse signing or another encryption domain" do
    put(%{"IDENTITY_SECRET_ENCRYPTION_KEY" => Base.encode64(String.duplicate("r", 32))})
    assert_raise RuntimeError, ~r/independent from signing, recovery/, fn -> runtime() end
    System.delete_env("IDENTITY_SECRET_ENCRYPTION_KEY")

    put(%{
      "PUSH_SUBSCRIPTION_ENCRYPTION_KEY" => Base.encode64(String.duplicate("p", 32)),
      "IDENTITY_SECRET_ENCRYPTION_KEYS_JSON" =>
        Jason.encode!(%{
          "primary" => Base.encode64(String.duplicate("i", 32)),
          "previous" => Base.encode64(String.duplicate("p", 32))
        })
    })

    assert_raise RuntimeError, ~r/must not be reused across webhook or push/, fn -> runtime() end
  end

  test "identity keyring duplicate identifiers, missing active keys and reserved IDs fail closed" do
    key = Base.encode64(String.duplicate("i", 32))

    put(%{
      "IDENTITY_SECRET_ENCRYPTION_KEYS_JSON" => "{\"primary\":\"#{key}\",\"primary\":\"#{key}\"}"
    })

    assert_raise RuntimeError, ~r/duplicate key identifiers/, fn -> runtime() end
    put(%{"IDENTITY_SECRET_ENCRYPTION_KEYS_JSON" => Jason.encode!(%{"previous" => key})})
    assert_raise RuntimeError, ~r/must contain its active key identifier/, fn -> runtime() end
    put(%{"IDENTITY_SECRET_ENCRYPTION_KEYS_JSON" => Jason.encode!(%{"legacy" => key})})
    assert_raise RuntimeError, ~r/reserved legacy/, fn -> runtime() end
  end

  test "identity keys cannot reuse provider credentials even while optional providers are disabled" do
    material = String.duplicate("i", 32)
    put(%{"IDENTITY_SECRET_ENCRYPTION_KEY" => Base.encode64(material)})

    for name <-
          ~w(OIDC_CLIENT_SECRET TELEPHONY_PBX_PASSWORD TELEPHONY_PBX_WEBHOOK_SECRET LIVEKIT_API_SECRET TURN_STATIC_AUTH_SECRET) do
      for credential <- [material, Base.encode64(material)] do
        System.put_env(name, credential)

        error =
          assert_raise RuntimeError, ~r/independent from signing, recovery/, fn -> runtime() end

        refute Exception.message(error) =~ credential
        System.delete_env(name)
      end
    end

    config = runtime()
    refute config[:comms_core][:oidc].enabled
    refute config[:comms_integrations][:telephony_pbx_enabled]
  end

  test "SSO requires explicit assurance, HTTPS issuer and approved callbacks as well as a dedicated encryption key" do
    put(%{
      "OIDC_ENABLED" => "true",
      "OIDC_ISSUER" => "https://idp.example.test/realm",
      "OIDC_CLIENT_ID" => "fixture-client",
      "OIDC_CLIENT_SECRET" => "fixture-secret-with-enough-length",
      "OIDC_REDIRECT_URI" => "https://comms.example.test/api/auth/oidc/callback",
      "OIDC_ALLOWED_REDIRECT_URIS_JSON" =>
        "[\"https://comms.example.test/api/auth/oidc/callback\"]",
      "OIDC_REQUIRED_ACR_VALUES" => "urn:fixture:mfa"
    })

    assert_raise RuntimeError, ~r/dedicated identity encryption key/, fn -> runtime() end
    put(%{"IDENTITY_SECRET_ENCRYPTION_KEY" => Base.encode64(String.duplicate("i", 32))})
    assert runtime()[:comms_core][:oidc].enabled
    put(%{"OIDC_ISSUER" => "http://idp.example.test/realm"})
    assert_raise RuntimeError, ~r/complete HTTPS identity configuration/, fn -> runtime() end
  end

  test "secret-file inputs reject arbitrary paths and never disclose credentials in failures" do
    put(%{"OIDC_CLIENT_SECRET_FILE" => "/tmp/sensitive-private-file"})
    error = assert_raise RuntimeError, fn -> runtime() end
    refute Exception.message(error) =~ "sensitive-private-file"
    System.delete_env("OIDC_CLIENT_SECRET_FILE")

    put(%{
      "OIDC_CLIENT_SECRET" => "do-not-log-this-value",
      "OIDC_CLIENT_SECRET_FILE" => "/run/secrets/oidc"
    })

    error = assert_raise RuntimeError, fn -> runtime() end
    assert Exception.message(error) =~ "mutually exclusive"
    refute Exception.message(error) =~ "do-not-log-this-value"
  end

  defp recording_scope,
    do: %{
      "MEETING_ARTIFACT_PRIVACY_APPROVED" => "true",
      "MEETING_ARTIFACT_PROVIDER_QUALIFIED" => "true",
      "MEETING_ARTIFACT_ENABLED_TENANT_IDS" => "4acf5490-60ba-439d-8a74-84960a9a1e4d",
      "AUDIO_PROVIDER_MODE" => "livekit",
      "LIVEKIT_API_URL" => "https://media.example.test",
      "LIVEKIT_SERVER_URL" => "wss://media.example.test",
      "LIVEKIT_API_KEY" => "fixture-api-key",
      "LIVEKIT_API_SECRET" => "fixture-api-secret-at-least-32-bytes"
    }

  defp put(values), do: Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

  defp runtime,
    do: Path.expand("../../../../config/runtime.exs", __DIR__) |> Config.Reader.read!(env: :prod)
end
