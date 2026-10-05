defmodule CommsCore.PrivateRooms.ClosedInputTest do
  use ExUnit.Case, async: true
  alias CommsCore.Accounts.MatrixSessions
  alias CommsCore.Messaging.PrivateEvents

  test "opaque transaction/device identities reject trailing controls and embedded line breaks" do
    content = %{
      "algorithm" => "m.megolm.v1.aes-sha2",
      "session_id" => Base.encode64(:binary.copy(<<1>>, 32), padding: false),
      "ciphertext" => Base.encode64(:binary.copy(<<2>>, 48), padding: false)
    }

    for control <- ["\n", "\r", "\r\n", <<0>>, <<127>>] do
      assert {:error, :invalid_opaque_private_event} =
               CommsCore.Messaging.PrivateEvents.validate(%{
                 transaction_id: "legitimate" <> control,
                 content: content
               })

      assert {:error, :invalid_opaque_private_event} =
               CommsCore.Messaging.PrivateEvents.validate(%{
                 transaction_id: "legitimate",
                 content: Map.put(content, "device_id", "KC_device" <> control)
               })
    end
  end

  test "opaque envelope rejects plaintext, malformed session/key bytes, unchecked optional fields and custom algorithms" do
    content = %{
      "algorithm" => "m.megolm.v1.aes-sha2",
      "session_id" => Base.encode64(:binary.copy(<<1>>, 32), padding: false),
      "ciphertext" => Base.encode64(:binary.copy(<<2>>, 48), padding: false)
    }

    assert :ok = PrivateEvents.validate(%{transaction_id: "stable-1", content: content})

    for bad <- [
          Map.put(content, "body", "plaintext"),
          Map.put(content, "session_id", "short"),
          Map.put(content, "sender_key", %{}),
          Map.put(content, "device_id", ["malicious"]),
          Map.put(content, "algorithm", "m.room.message"),
          Map.put(content, "ciphertext", String.duplicate("A", 100_000))
        ] do
      assert {:error, :invalid_opaque_private_event} =
               PrivateEvents.validate(%{transaction_id: "stable-1", content: bad})
    end
  end

  test "cross-signing endpoint only accepts exact public ed25519 fields and rejects private/auth data" do
    public = Base.encode64(:binary.copy(<<1>>, 32), padding: false)

    key = %{
      "user_id" => "@person:example.test",
      "usage" => ["master"],
      "keys" => %{("ed25519:" <> public) => public}
    }

    assert :ok = MatrixSessions.validate_signing_keys(%{"master_key" => key})

    for bad <- [
          %{"master_key" => Map.put(key, "private_key", "secret")},
          %{
            "master_key" =>
              Map.put(key, "keys", %{("ed25519:" <> public) => %{private: "secret"}})
          },
          %{"master_key" => Map.put(key, "usage", ["user_signing"])},
          %{"master_key" => key, "auth" => %{password: "secret"}}
        ] do
      assert {:error, :invalid_public_signing_keys} = MatrixSessions.validate_signing_keys(bad)
    end
  end
end
