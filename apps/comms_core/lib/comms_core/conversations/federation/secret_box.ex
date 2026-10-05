defmodule CommsCore.Conversations.Federation.SecretBox do
  @moduledoc "Dedicated AES-256-GCM envelope; authenticated tenant, row and purpose binding."
  @spec seal(binary(), binary(), binary(), term()) :: binary()
  def seal(tenant, id, purpose, value) do
    key = key!()
    nonce = :crypto.strong_rand_bytes(12)

    {cipher, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        Jason.encode!(value),
        aad(tenant, id, purpose),
        true
      )

    <<1, nonce::binary-size(12), tag::binary-size(16), cipher::binary>>
  end

  @spec open(binary(), binary(), binary(), binary()) :: {:ok, term()} | {:error, atom()}
  def open(
        tenant,
        id,
        purpose,
        <<1, nonce::binary-size(12), tag::binary-size(16), cipher::binary>>
      ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key!(),
           nonce,
           cipher,
           aad(tenant, id, purpose),
           tag,
           false
         ) do
      :error -> {:error, :invalid_federation_envelope}
      plain -> Jason.decode(plain)
    end
  rescue
    _ -> {:error, :invalid_federation_envelope}
  end

  def open(_, _, _, _), do: {:error, :invalid_federation_envelope}
  def hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp aad(tenant, id, purpose),
    do: "k-comms/federation/v1/" <> tenant <> "/" <> id <> "/" <> purpose

  defp key! do
    case Application.fetch_env!(:comms_core, :federation_envelope_key) do
      key when is_binary(key) and byte_size(key) == 32 -> key
      _ -> raise "dedicated federation envelope key is unavailable"
    end
  end
end
