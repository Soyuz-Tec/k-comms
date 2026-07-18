defmodule CommsCore.Security.SecretBox do
  @aad_prefix "k-comms-webhook-secret:v2"
  @key_bytes 32
  @nonce_bytes 12
  @tag_bytes 16
  @key_id_pattern ~r/^[A-Za-z0-9_.-]{1,64}$/

  def status do
    case keyring() do
      {:ok, current_key_id, keys} ->
        %{status: :available, current_key_id: current_key_id, key_count: map_size(keys)}

      {:error, reason} ->
        %{status: :unavailable, reason: reason}
    end
  end

  def encrypt(plaintext, context) when is_binary(plaintext) and byte_size(plaintext) >= 16 do
    with {:ok, current_key_id, keys} <- keyring(),
         {:ok, key} <- Map.fetch(keys, current_key_id),
         {:ok, aad} <- contextual_aad(context, current_key_id) do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, @tag_bytes, true)

      {:ok, %{ciphertext: ciphertext, nonce: nonce, tag: tag, key_id: current_key_id}}
    else
      :error -> {:error, :secret_encryption_key_not_configured}
      {:error, _} = error -> error
    end
  end

  def encrypt(_, _), do: {:error, :invalid_secret}

  def decrypt(%{ciphertext: ciphertext, nonce: nonce, tag: tag} = encrypted, context)
      when is_binary(ciphertext) and byte_size(ciphertext) > 0 and is_binary(nonce) and
             byte_size(nonce) == @nonce_bytes and is_binary(tag) and byte_size(tag) == @tag_bytes do
    key_id = value(encrypted, :key_id) || "legacy"

    with {:ok, _current_key_id, keys} <- keyring(),
         {:ok, key} <- fetch_key(keys, key_id),
         {:ok, aad} <- aad_for_decryption(context, key_id),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      :error -> {:error, :secret_decryption_failed}
      {:error, _} = error -> error
      _ -> {:error, :secret_decryption_failed}
    end
  rescue
    _ -> {:error, :secret_decryption_failed}
  end

  def decrypt(_, _), do: {:error, :secret_decryption_failed}

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

    with :ok <- validate_current_key_id(current_key_id),
         {:ok, keys} <- decode_keys(source),
         true <-
           Map.has_key?(keys, current_key_id) || {:error, :current_secret_key_not_configured} do
      {:ok, current_key_id, keys}
    else
      false -> {:error, :current_secret_key_not_configured}
      {:error, _} = error -> error
    end
  end

  defp decode_keys(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn {key_id, encoded}, {:ok, acc} ->
      key_id = to_string(key_id)

      with :ok <- validate_key_id(key_id),
           {:ok, key} <- decode_key(encoded) do
        {:cont, {:ok, Map.put(acc, key_id, key)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_key_id(key_id) when is_binary(key_id) do
    if Regex.match?(@key_id_pattern, key_id),
      do: :ok,
      else: {:error, :invalid_secret_encryption_key_id}
  end

  defp validate_key_id(_), do: {:error, :invalid_secret_encryption_key_id}

  defp validate_current_key_id("legacy"), do: {:error, :legacy_secret_encryption_key_id}
  defp validate_current_key_id(key_id), do: validate_key_id(key_id)

  defp decode_key(key) when is_binary(key) and byte_size(key) == @key_bytes, do: {:ok, key}

  defp decode_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
      _ -> {:error, :invalid_secret_encryption_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_secret_encryption_key}

  defp fetch_key(keys, key_id) do
    case Map.fetch(keys, key_id) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :secret_encryption_key_unavailable}
    end
  end

  # Version-one webhook ciphertext was not bound to its tenant, endpoint, or
  # version. Refuse it instead of retaining a cross-context decryption path;
  # administrators can replace the endpoint secret through the audited,
  # versioned rotation operation.
  defp aad_for_decryption(_context, "legacy"), do: {:error, :legacy_secret_requires_rotation}
  defp aad_for_decryption(context, key_id), do: contextual_aad(context, key_id)

  defp contextual_aad(context, key_id) when is_map(context) do
    tenant_id = value(context, :tenant_id)
    endpoint_id = value(context, :endpoint_id)
    version = value(context, :version)

    if is_binary(tenant_id) and is_binary(endpoint_id) and is_integer(version) and version > 0 do
      {:ok, Enum.join([@aad_prefix, key_id, tenant_id, endpoint_id, version], ":")}
    else
      {:error, :invalid_secret_context}
    end
  end

  defp contextual_aad(_, _), do: {:error, :invalid_secret_context}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
