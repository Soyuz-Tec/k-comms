defmodule CommsCore.AudioCalls.CalendarSync.SecretBox do
  @moduledoc false
  alias CommsCore.AudioCalls.CalendarSync.SecretContext

  @key_id ~r/^[A-Za-z0-9_.-]{1,64}$/
  @maximum_plaintext 65_536

  def status do
    case keyring() do
      {:ok, current, keys} ->
        %{status: :available, current_key_id: current, key_count: map_size(keys)}

      {:error, reason} ->
        %{status: :unavailable, reason: reason}
    end
  end

  def encrypt(plaintext, %SecretContext{} = context)
      when is_binary(plaintext) and byte_size(plaintext) in 1..@maximum_plaintext do
    with {:ok, current, keys} <- keyring(),
         {:ok, aad} <- aad(context, current) do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, keys[current], nonce, plaintext, aad, 16, true)

      {:ok, %{key_id: current, ciphertext: ciphertext, nonce: nonce, tag: tag}}
    end
  end

  def encrypt(_, _), do: {:error, :invalid_calendar_secret}

  def decrypt(
        %{key_id: id, ciphertext: cipher, nonce: nonce, tag: tag},
        %SecretContext{} = context
      )
      when is_binary(id) and is_binary(cipher) and byte_size(cipher) in 1..@maximum_plaintext and
             is_binary(nonce) and byte_size(nonce) == 12 and is_binary(tag) and
             byte_size(tag) == 16 do
    with {:ok, _, keys} <- keyring(),
         {:ok, key} <- Map.fetch(keys, id),
         {:ok, aad} <- aad(context, id),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, cipher, aad, tag, false) do
      {:ok, plaintext}
    else
      _ -> {:error, :calendar_secret_unavailable}
    end
  rescue
    _ -> {:error, :calendar_secret_unavailable}
  end

  def decrypt(_, _), do: {:error, :calendar_secret_unavailable}

  defp keyring do
    config = Application.get_env(:comms_core, :calendar_secret_keyring, %{})
    current = config[:current_key_id]
    configured = config[:keys]

    with true <- valid_key_id?(current),
         true <- is_map(configured) and map_size(configured) in 1..8,
         {:ok, keys} <- decode_keys(configured),
         true <- Map.has_key?(keys, current) do
      {:ok, current, keys}
    else
      _ -> {:error, :calendar_secret_keyring_not_configured}
    end
  end

  defp decode_keys(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn {id, value}, {:ok, acc} ->
      with true <- valid_key_id?(id),
           {:ok, key} <- decode_key(value) do
        {:cont, {:ok, Map.put(acc, id, key)}}
      else
        _ -> {:halt, {:error, :invalid_calendar_secret_key}}
      end
    end)
  end

  defp decode_key(key) when is_binary(key) and byte_size(key) == 32, do: {:ok, key}

  defp decode_key(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :invalid_calendar_secret_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_calendar_secret_key}
  defp valid_key_id?(id), do: is_binary(id) and Regex.match?(@key_id, id)

  defp aad(%SecretContext{} = context, key_id) do
    ids = [context.tenant_id, context.user_id, context.resource_id]

    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) and
         context.provider in [:google, :microsoft] and
         context.purpose in [:challenge, :credential, :external_identity, :event_identity] and
         is_integer(context.generation) and context.generation > 0 do
      {:ok,
       :erlang.term_to_binary(
         {:k_comms_calendar_secret_v1, key_id, context.tenant_id, context.user_id,
          context.provider, context.resource_id, context.generation, context.purpose}
       )}
    else
      {:error, :invalid_calendar_secret_context}
    end
  end
end
