defmodule CommsIntegrations.NativePushProviderTest do
  use ExUnit.Case, async: false
  alias CommsCore.Notifications.NativeDelivery
  alias CommsIntegrations.NativePush.{Provider, ProviderTokens}
  @moduletag :unit
  @moduletag :external_delivery

  setup do
    keys = [
      :native_push_provider_enabled,
      :native_push_channels,
      :native_push_apns,
      :native_push_fcm
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:comms_integrations, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_integrations, key, value)
        {key, :error} -> Application.delete_env(:comms_integrations, key)
      end)
    end)

    Enum.each(keys, &Application.delete_env(:comms_integrations, &1))
    :ok
  end

  test "default-off configuration and malformed approved channel lists remain unavailable" do
    assert Provider.status() == %{status: :unavailable, channels: []}
    Application.put_env(:comms_integrations, :native_push_provider_enabled, true)

    for channels <- [[], ["fcm", "fcm"], ["fcm", "unknown"], "fcm", nil] do
      Application.put_env(:comms_integrations, :native_push_channels, channels)
      assert Provider.status() == %{status: :unavailable, channels: []}
      assert Provider.deliver(delivery(), deadline()) == {:error, :unavailable}
    end
  end

  test "Edge capability is configuration-only and unapproved channels cannot read transport files" do
    Application.put_env(:comms_integrations, :native_push_provider_enabled, true)
    Application.put_env(:comms_integrations, :native_push_channels, ["fcm"])

    Application.put_env(:comms_integrations, :native_push_apns,
      private_key_file: "/not-a-provider-secret"
    )

    assert Provider.status() == %{status: :available, channels: ["fcm"]}
    assert Provider.deliver(delivery(), deadline()) == {:error, :unavailable}

    assert Provider.deliver(
             %{delivery() | channel: "fcm", platform: "android", environment: "production"},
             deadline()
           ) == {:error, :unavailable}
  end

  test "provider payload and Inspect contain no call, identity, caller or transport token" do
    value = delivery()

    assert Provider.payload(value) == %{
             "protocol_version" => "1",
             "wake_id" => value.wake_id,
             "expires_at" => DateTime.to_iso8601(value.expires_at),
             "kind" => "call"
           }

    refute inspect(value) =~ value.token
    refute Jason.encode!(Provider.payload(value)) =~ value.token

    assert Provider.deliver(
             %{value | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)},
             deadline()
           ) == {:error, :unavailable}
  end

  test "private file policy refuses traversal, symlinks, group access and unbounded material" do
    root =
      Path.join(System.tmp_dir!(), "native-provider-policy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "synthetic.pem")
    File.write!(path, "synthetic-private-key")
    File.chmod!(path, 0o600)
    assert ProviderTokens.private_file?(path, root)
    File.chmod!(path, 0o640)
    refute ProviderTokens.private_file?(path, root)
    File.chmod!(path, 0o400)
    assert ProviderTokens.private_file?(path, root)
    link = Path.join(root, "linked.pem")
    File.ln_s!(path, link)
    refute ProviderTokens.private_file?(link, root)

    refute ProviderTokens.private_file?(
             root <> "/../" <> Path.basename(root) <> "/synthetic.pem",
             root
           )

    refute ProviderTokens.private_file?(path, "/run/secrets")
    File.chmod!(path, 0o600)
    File.write!(path, String.duplicate("x", 16_385))
    refute ProviderTokens.private_file?(path, root)
    File.write!(path, "")
    refute ProviderTokens.private_file?(path, root)
    # Actual credential reads keep the production root even for a valid private
    # synthetic file. A generic temporary key cannot be used for signing.
    Application.put_env(:comms_integrations, :native_push_apns,
      key_id: "ABCDEFGHIJ",
      team_id: "KLMNOPQRST",
      private_key_file: path
    )

    assert ProviderTokens.apns() == {:error, :native_push_credentials_unavailable}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000

  defp delivery,
    do: %NativeDelivery{
      wake_id: Ecto.UUID.generate(),
      registration_id: Ecto.UUID.generate(),
      registration_version: 1,
      platform: "ios",
      channel: "apns_voip",
      application_id: "com.synthetic.native",
      environment: "sandbox",
      token: String.duplicate("a", 64),
      expires_at: DateTime.add(DateTime.utc_now(), 25, :second)
    }
end
