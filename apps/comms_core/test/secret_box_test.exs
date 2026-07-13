defmodule CommsCore.SecretBoxTest do
  use ExUnit.Case, async: false

  alias CommsCore.Security.SecretBox

  setup do
    keys = [
      webhook_secret_encryption_key:
        Application.get_env(:comms_core, :webhook_secret_encryption_key),
      webhook_secret_encryption_key_id:
        Application.get_env(:comms_core, :webhook_secret_encryption_key_id),
      webhook_secret_encryption_keys:
        Application.get_env(:comms_core, :webhook_secret_encryption_keys)
    ]

    on_exit(fn ->
      Enum.each(keys, fn
        {key, nil} -> Application.delete_env(:comms_core, key)
        {key, value} -> Application.put_env(:comms_core, key, value)
      end)
    end)

    :ok
  end

  test "ciphertext is context-bound, shape-checked, and decryptable across an explicit key rotation" do
    key_a = :binary.copy(<<1>>, 32)
    key_b = :binary.copy(<<2>>, 32)
    context = %{tenant_id: "tenant-a", endpoint_id: "endpoint-a", version: 1}

    Application.put_env(:comms_core, :webhook_secret_encryption_key_id, "key-a")
    Application.put_env(:comms_core, :webhook_secret_encryption_keys, %{"key-a" => key_a})

    assert {:ok, encrypted} = SecretBox.encrypt("a-long-webhook-signing-secret", context)
    assert encrypted.key_id == "key-a"
    assert {:ok, "a-long-webhook-signing-secret"} = SecretBox.decrypt(encrypted, context)

    assert {:error, :secret_decryption_failed} =
             SecretBox.decrypt(encrypted, %{context | tenant_id: "tenant-b"})

    assert {:error, :secret_decryption_failed} =
             SecretBox.decrypt(%{encrypted | nonce: <<0>>}, context)

    assert {:error, :secret_decryption_failed} =
             SecretBox.decrypt(%{encrypted | tag: :binary.copy(<<0>>, 16)}, context)

    Application.put_env(:comms_core, :webhook_secret_encryption_key_id, "key-b")

    Application.put_env(:comms_core, :webhook_secret_encryption_keys, %{
      "key-a" => key_a,
      "key-b" => key_b
    })

    assert {:ok, "a-long-webhook-signing-secret"} = SecretBox.decrypt(encrypted, context)
    assert %{status: :available, current_key_id: "key-b", key_count: 2} = SecretBox.status()

    Application.put_env(:comms_core, :webhook_secret_encryption_keys, %{"key-b" => key_b})
    assert {:error, :secret_encryption_key_unavailable} = SecretBox.decrypt(encrypted, context)
  end

  test "invalid key sizes fail closed" do
    Application.put_env(:comms_core, :webhook_secret_encryption_key_id, "primary")
    Application.put_env(:comms_core, :webhook_secret_encryption_keys, %{"primary" => "short"})

    assert %{status: :unavailable, reason: :invalid_secret_encryption_key} = SecretBox.status()

    assert {:error, :invalid_secret_encryption_key} =
             SecretBox.encrypt(
               "a-long-webhook-signing-secret",
               %{tenant_id: "tenant", endpoint_id: "endpoint", version: 1}
             )
  end

  test "legacy ciphertext fails closed even when a legacy key is configured" do
    key = :binary.copy(<<3>>, 32)
    nonce = :binary.copy(<<4>>, 12)
    plaintext = "a-long-legacy-webhook-secret"

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        "k-comms-webhook-secret:v1",
        16,
        true
      )

    Application.put_env(:comms_core, :webhook_secret_encryption_key_id, "primary")

    Application.put_env(:comms_core, :webhook_secret_encryption_keys, %{
      "primary" => key,
      "legacy" => key
    })

    assert {:error, :legacy_secret_requires_rotation} =
             SecretBox.decrypt(
               %{ciphertext: ciphertext, nonce: nonce, tag: tag, key_id: "legacy"},
               %{tenant_id: "tenant-a", endpoint_id: "endpoint-a", version: 1}
             )
  end

  test "legacy cannot be configured as the current encryption key identifier" do
    Application.put_env(:comms_core, :webhook_secret_encryption_key_id, "legacy")

    Application.put_env(:comms_core, :webhook_secret_encryption_keys, %{
      "legacy" => :binary.copy(<<5>>, 32)
    })

    assert %{status: :unavailable, reason: :legacy_secret_encryption_key_id} = SecretBox.status()

    assert {:error, :legacy_secret_encryption_key_id} =
             SecretBox.encrypt(
               "a-long-webhook-signing-secret",
               %{tenant_id: "tenant-a", endpoint_id: "endpoint-a", version: 1}
             )
  end
end
