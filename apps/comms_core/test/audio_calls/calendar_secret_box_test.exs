defmodule CommsCore.AudioCalls.CalendarSecretBoxTest do
  use ExUnit.Case, async: false
  alias CommsCore.AudioCalls.CalendarSync.{SecretBox, SecretContext}

  setup do
    previous = Application.get_env(:comms_core, :calendar_secret_keyring)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:comms_core, :calendar_secret_keyring),
        else: Application.put_env(:comms_core, :calendar_secret_keyring, previous)
    end)

    keys = %{
      "current" => :crypto.strong_rand_bytes(32),
      "previous" => :crypto.strong_rand_bytes(32)
    }

    Application.put_env(:comms_core, :calendar_secret_keyring, %{
      current_key_id: "current",
      keys: keys
    })

    {:ok,
     keys: keys,
     context: %SecretContext{
       tenant_id: Ecto.UUID.generate(),
       user_id: Ecto.UUID.generate(),
       provider: :google,
       resource_id: Ecto.UUID.generate(),
       generation: 1,
       purpose: :credential
     }}
  end

  test "calendar credentials decrypt only under every original ownership and purpose field", %{
    context: context
  } do
    {:ok, encrypted} = SecretBox.encrypt("synthetic-calendar-refresh-token", context)
    assert {:ok, "synthetic-calendar-refresh-token"} = SecretBox.decrypt(encrypted, context)

    alternatives = [
      tenant_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      provider: :microsoft,
      resource_id: Ecto.UUID.generate(),
      generation: 2,
      purpose: :challenge
    ]

    for {field, value} <- alternatives do
      assert {:error, :calendar_secret_unavailable} =
               SecretBox.decrypt(encrypted, Map.put(context, field, value))
    end
  end

  test "key identifiers reject trailing newline and control characters", %{context: context} do
    for id <- ["key\n", "key\r", "key\t", "key ", "key" <> <<127>>] do
      Application.put_env(:comms_core, :calendar_secret_keyring, %{
        current_key_id: id,
        keys: %{id => :crypto.strong_rand_bytes(32)}
      })

      assert {:error, :calendar_secret_keyring_not_configured} =
               SecretBox.encrypt("token", context)
    end
  end

  test "rotation preserves old material until its exact key is explicitly retired", %{
    context: context,
    keys: keys
  } do
    Application.put_env(:comms_core, :calendar_secret_keyring, %{
      current_key_id: "previous",
      keys: keys
    })

    {:ok, old} = SecretBox.encrypt("old-calendar-token", context)

    Application.put_env(:comms_core, :calendar_secret_keyring, %{
      current_key_id: "current",
      keys: keys
    })

    assert {:ok, "old-calendar-token"} = SecretBox.decrypt(old, context)
    {:ok, new} = SecretBox.encrypt("new-calendar-token", %{context | generation: 2})
    assert new.key_id == "current"

    Application.put_env(:comms_core, :calendar_secret_keyring, %{
      current_key_id: "current",
      keys: Map.delete(keys, "previous")
    })

    assert {:error, :calendar_secret_unavailable} = SecretBox.decrypt(old, context)
    assert {:ok, "new-calendar-token"} = SecretBox.decrypt(new, %{context | generation: 2})
  end

  test "tampered material, invalid context and absent current key fail closed", %{
    context: context,
    keys: keys
  } do
    {:ok, box} = SecretBox.encrypt("synthetic-calendar-token", context)

    assert {:error, :calendar_secret_unavailable} =
             SecretBox.decrypt(%{box | tag: <<0::128>>}, context)

    assert {:error, :invalid_calendar_secret_context} =
             SecretBox.encrypt("token", %{context | generation: 0})

    assert {:error, :invalid_calendar_secret} = SecretBox.encrypt("", context)

    Application.put_env(:comms_core, :calendar_secret_keyring, %{
      current_key_id: "missing",
      keys: keys
    })

    assert %{status: :unavailable} = SecretBox.status()
    assert {:error, :calendar_secret_keyring_not_configured} = SecretBox.encrypt("token", context)
  end

  test "calendar material cannot decrypt with an Accounts key merely because bytes match", %{
    context: context,
    keys: keys
  } do
    {:ok, box} = SecretBox.encrypt("dedicated-calendar-secret", context)
    previous = Application.get_env(:comms_core, :identity_secret_encryption_key)
    Application.put_env(:comms_core, :identity_secret_encryption_key, keys["current"])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:comms_core, :identity_secret_encryption_key),
        else: Application.put_env(:comms_core, :identity_secret_encryption_key, previous)
    end)

    Application.delete_env(:comms_core, :calendar_secret_keyring)
    assert {:error, :calendar_secret_unavailable} = SecretBox.decrypt(box, context)
  end
end
