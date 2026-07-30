defmodule CommsCore.Release.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :release

  test "each runtime boot gets a bounded unique database application name" do
    runtime_environment = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/k_comms_runtime_config_test",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "K_COMMS_ROLE" => "migration-operator-role",
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_INSTANCE_ID" => "migration-host-with-a-stable-instance-identifier",
      "PUBLIC_APP_URL" => "https://comms.example.test",
      "PASSWORD_RECOVERY_SIGNING_KEY" => String.duplicate("r", 32),
      "S3_ACCESS_KEY_ID" => "runtime-config-test-access",
      "S3_SECRET_ACCESS_KEY" => "runtime-config-test-secret"
    }

    previous_environment =
      Map.new(runtime_environment, fn {variable, _value} ->
        {variable, System.get_env(variable)}
      end)

    Enum.each(runtime_environment, fn {variable, value} -> System.put_env(variable, value) end)

    on_exit(fn ->
      Enum.each(previous_environment, fn {variable, value} ->
        restore_environment(variable, value)
      end)
    end)

    first = runtime_database_application_name!()
    second = runtime_database_application_name!()

    assert byte_size(first) <= 63
    assert byte_size(second) <= 63
    assert first != second

    expected_instance_digest =
      :sha256
      |> :crypto.hash(runtime_environment["K_COMMS_INSTANCE_ID"])
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    assert ["k_comms", "one_shot", "migration-op", first_nonce, ^expected_instance_digest] =
             String.split(first, "/")

    assert ["k_comms", "one_shot", "migration-op", second_nonce, ^expected_instance_digest] =
             String.split(second, "/")

    assert first_nonce =~ ~r/^[A-Za-z0-9_-]{16}$/
    assert second_nonce =~ ~r/^[A-Za-z0-9_-]{16}$/
    assert first_nonce != second_nonce
  end

  test "runtime rejects weak endpoint signing keys and database TLS URL overrides" do
    base_environment = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/k_comms_runtime_config_test",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "K_COMMS_ROLE" => "migration-operator-role",
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_INSTANCE_ID" => "runtime-security-test-instance",
      "PUBLIC_APP_URL" => "https://comms.example.test",
      "PASSWORD_RECOVERY_SIGNING_KEY" => String.duplicate("r", 32),
      "S3_ACCESS_KEY_ID" => "runtime-config-test-access",
      "S3_SECRET_ACCESS_KEY" => "runtime-config-test-secret"
    }

    assert_runtime_config_rejected!(
      Map.put(base_environment, "SECRET_KEY_BASE", "too-short"),
      "SECRET_KEY_BASE must contain at least 64 bytes"
    )

    assert_runtime_config_rejected!(
      Map.update!(base_environment, "DATABASE_URL", &(&1 <> "?ssl=false")),
      "DATABASE_URL must not override the runtime TLS policy with an ssl query parameter"
    )
  end

  defp runtime_database_application_name! do
    runtime_config =
      Path.expand("../../../../config/runtime.exs", __DIR__)
      |> Config.Reader.read!(env: :prod)

    runtime_config
    |> Keyword.fetch!(:comms_core)
    |> Keyword.fetch!(CommsCore.Repo)
    |> Keyword.fetch!(:parameters)
    |> Keyword.fetch!(:application_name)
  end

  defp assert_runtime_config_rejected!(environment, message) do
    previous_environment =
      Map.new(environment, fn {variable, _value} ->
        {variable, System.get_env(variable)}
      end)

    try do
      Enum.each(environment, fn {variable, value} -> System.put_env(variable, value) end)

      assert_raise RuntimeError, message, fn ->
        Path.expand("../../../../config/runtime.exs", __DIR__)
        |> Config.Reader.read!(env: :prod)
      end
    after
      Enum.each(previous_environment, fn {variable, value} ->
        restore_environment(variable, value)
      end)
    end
  end

  defp restore_environment(variable, nil), do: System.delete_env(variable)
  defp restore_environment(variable, value), do: System.put_env(variable, value)
end
