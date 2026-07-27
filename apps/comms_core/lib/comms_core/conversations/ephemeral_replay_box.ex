defmodule CommsCore.Conversations.EphemeralReplayBox do
  @moduledoc false

  @aad_prefix "k-comms:ephemeral-room-replay:v2"
  @legacy_aad_prefix "k-comms:ephemeral-room-replay:v1"
  @key_derivation_context "k-comms:ephemeral-room-replay:key:v1"
  @key_bytes 32
  @nonce_bytes 12
  @tag_bytes 16
  @key_id_pattern ~r/^[A-Za-z0-9_.-]{1,64}$/

  def encrypt(token, tenant_id, room_id)
      when is_binary(token) and is_binary(tenant_id) and is_binary(room_id) do
    with {:ok, current_key_id, keys} <- keyring(),
         {:ok, master_key} <- Map.fetch(keys, current_key_id) do
      key = derive_key(master_key)
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      aad = aad(current_key_id, tenant_id, room_id)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, token, aad, @tag_bytes, true)

      {:ok, %{ciphertext: ciphertext, nonce: nonce, tag: tag, key_id: current_key_id}}
    else
      :error -> {:error, :ephemeral_replay_encryption_unavailable}
      {:error, _} = error -> error
    end
  end

  def encrypt(_, _, _), do: {:error, :invalid_ephemeral_replay_material}

  def decrypt(room) when is_map(room) do
    with ciphertext when is_binary(ciphertext) <- value(room, :replay_ciphertext),
         nonce when is_binary(nonce) and byte_size(nonce) == @nonce_bytes <-
           value(room, :replay_nonce),
         tag when is_binary(tag) and byte_size(tag) == @tag_bytes <- value(room, :replay_tag),
         key_id when is_binary(key_id) <- value(room, :replay_key_id),
         tenant_id when is_binary(tenant_id) <- value(room, :tenant_id),
         room_id when is_binary(room_id) <- value(room, :id),
         {:ok, _current_key_id, keys} <- keyring(),
         {:ok, master_key} <- Map.fetch(keys, key_id),
         token when is_binary(token) <-
           decrypt_token(
             master_key,
             key_id,
             tenant_id,
             room_id,
             nonce,
             ciphertext,
             tag
           ) do
      {:ok, token}
    else
      _ -> {:error, :ephemeral_replay_unavailable}
    end
  rescue
    _ -> {:error, :ephemeral_replay_unavailable}
  end

  defp keyring do
    current_key_id =
      Application.get_env(:comms_core, :webhook_secret_encryption_key_id, "primary")
      |> to_string()

    configured_keys = Application.get_env(:comms_core, :webhook_secret_encryption_keys)

    source =
      if is_map(configured_keys) and map_size(configured_keys) > 0 do
        configured_keys
      else
        case Application.get_env(:comms_core, :webhook_secret_encryption_key) do
          nil -> %{}
          key -> %{current_key_id => key}
        end
      end

    with true <- Regex.match?(@key_id_pattern, current_key_id),
         {:ok, keys} <- decode_keys(source),
         true <- Map.has_key?(keys, current_key_id) do
      {:ok, current_key_id, keys}
    else
      _ -> {:error, :ephemeral_replay_encryption_unavailable}
    end
  end

  defp decode_keys(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn {key_id, encoded}, {:ok, acc} ->
      key_id = to_string(key_id)

      case decode_key(encoded) do
        {:ok, key} ->
          if Regex.match?(@key_id_pattern, key_id) do
            {:cont, {:ok, Map.put(acc, key_id, key)}}
          else
            {:halt, {:error, :ephemeral_replay_encryption_unavailable}}
          end

        _ ->
          {:halt, {:error, :ephemeral_replay_encryption_unavailable}}
      end
    end)
  end

  defp decode_key(key) when is_binary(key) and byte_size(key) == @key_bytes, do: {:ok, key}

  defp decode_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
      _ -> {:error, :invalid_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_key}

  defp decrypt_token(master_key, key_id, tenant_id, room_id, nonce, ciphertext, tag) do
    decrypt_with_key(
      derive_key(master_key),
      nonce,
      ciphertext,
      aad(key_id, tenant_id, room_id),
      tag
    ) ||
      decrypt_with_key(
        master_key,
        nonce,
        ciphertext,
        legacy_aad(key_id, tenant_id, room_id),
        tag
      )
  end

  defp decrypt_with_key(key, nonce, ciphertext, aad, tag) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           aad,
           tag,
           false
         ) do
      token when is_binary(token) -> token
      _ -> nil
    end
  end

  defp derive_key(master_key),
    do: :crypto.mac(:hmac, :sha256, master_key, @key_derivation_context)

  defp aad(key_id, tenant_id, room_id),
    do: Enum.join([@aad_prefix, key_id, tenant_id, room_id], ":")

  defp legacy_aad(key_id, tenant_id, room_id),
    do: Enum.join([@legacy_aad_prefix, key_id, tenant_id, room_id], ":")

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
