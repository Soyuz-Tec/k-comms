defmodule CommsCore.EphemeralReplayBoxTest do
  use ExUnit.Case, async: true

  alias CommsCore.Conversations.EphemeralReplayBox

  test "new replay capsules use a purpose-derived key and legacy capsules remain readable" do
    token = :crypto.strong_rand_bytes(32)
    tenant_id = Ecto.UUID.generate()
    room_id = Ecto.UUID.generate()
    master_key = Application.fetch_env!(:comms_core, :webhook_secret_encryption_key)

    assert {:ok, capsule} = EphemeralReplayBox.encrypt(token, tenant_id, room_id)

    v2_aad =
      Enum.join(
        ["k-comms:ephemeral-room-replay:v2", capsule.key_id, tenant_id, room_id],
        ":"
      )

    assert :error ==
             :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               master_key,
               capsule.nonce,
               capsule.ciphertext,
               v2_aad,
               capsule.tag,
               false
             )

    assert {:ok, ^token} =
             EphemeralReplayBox.decrypt(%{
               replay_ciphertext: capsule.ciphertext,
               replay_nonce: capsule.nonce,
               replay_tag: capsule.tag,
               replay_key_id: capsule.key_id,
               tenant_id: tenant_id,
               id: room_id
             })

    legacy_nonce = :crypto.strong_rand_bytes(12)

    legacy_aad =
      Enum.join(["k-comms:ephemeral-room-replay:v1", "primary", tenant_id, room_id], ":")

    {legacy_ciphertext, legacy_tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        master_key,
        legacy_nonce,
        token,
        legacy_aad,
        16,
        true
      )

    assert {:ok, ^token} =
             EphemeralReplayBox.decrypt(%{
               replay_ciphertext: legacy_ciphertext,
               replay_nonce: legacy_nonce,
               replay_tag: legacy_tag,
               replay_key_id: "primary",
               tenant_id: tenant_id,
               id: room_id
             })
  end
end
