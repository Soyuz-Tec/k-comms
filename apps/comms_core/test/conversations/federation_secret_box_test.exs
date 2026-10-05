defmodule CommsCore.Conversations.FederationSecretBoxTest do
  use ExUnit.Case, async: false
  alias CommsCore.Conversations.Federation.SecretBox
  @moduletag :unit
  test "AEAD rejects foreign tenant, row, purpose and tampered payloads" do
    previous = Application.get_env(:comms_core, :federation_envelope_key)
    Application.put_env(:comms_core, :federation_envelope_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :federation_envelope_key, previous),
        else: Application.delete_env(:comms_core, :federation_envelope_key)
    end)

    box = SecretBox.seal("tenant-a", "row-a", "command", %{body: "synthetic"})
    assert {:ok, %{"body" => "synthetic"}} = SecretBox.open("tenant-a", "row-a", "command", box)

    for {tenant, row, purpose} <- [
          {"tenant-b", "row-a", "command"},
          {"tenant-a", "row-b", "command"},
          {"tenant-a", "row-a", "receipt"}
        ] do
      assert {:error, :invalid_federation_envelope} = SecretBox.open(tenant, row, purpose, box)
    end

    <<prefix::binary-size(10), byte, suffix::binary>> = box

    assert {:error, :invalid_federation_envelope} =
             SecretBox.open(
               "tenant-a",
               "row-a",
               "command",
               <<prefix::binary, Bitwise.bxor(byte, 1), suffix::binary>>
             )
  end
end
