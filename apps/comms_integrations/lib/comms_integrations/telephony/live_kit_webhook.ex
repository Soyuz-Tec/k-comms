defmodule CommsIntegrations.Telephony.LiveKitWebhook do
  @moduledoc "Authenticates the exact LiveKit webhook bytes before decoding provider JSON."

  alias CommsIntegrations.Telephony.Config
  @maximum_body_bytes 262_144

  def verify(body, authorization)
      when is_binary(body) and byte_size(body) <= @maximum_body_bytes and is_binary(authorization) do
    # The admission switch controls new calls, not the authentication of
    # already active call endings. Keep lifecycle convergence authenticated
    # with the same protected credentials used for reconciliation and cleanup.
    with {:ok, %{enabled: true} = config} <- Config.control_configuration(),
         {:ok, token} <- token(authorization),
         [header, payload, signature] <- String.split(token, "."),
         {:ok, decoded_header} <- decode_json(header),
         true <- decoded_header["alg"] == "HS256" and decoded_header["typ"] in [nil, "JWT"],
         {:ok, decoded_signature} <- Base.url_decode64(signature, padding: false),
         true <-
           secure_compare(
             decoded_signature,
             :crypto.mac(:hmac, :sha256, config.api_secret, header <> "." <> payload)
           ),
         {:ok, claims} <- decode_json(payload),
         true <- claims["iss"] == config.api_key and valid_times?(claims),
         hash when is_binary(hash) <- claims["sha256"],
         {:ok, decoded_hash} <- Base.decode64(hash),
         true <- secure_compare(decoded_hash, :crypto.hash(:sha256, body)),
         {:ok, event} when is_map(event) <- Jason.decode(body) do
      {:ok, event}
    else
      {:ok, %{enabled: false}} ->
        {:error, :telephony_provider_unavailable}

      {:error, reason}
      when reason in [
             :telephony_provider_mode,
             :audio_provider_mode,
             :livekit_server_url,
             :livekit_api_url,
             :livekit_api_key,
             :livekit_api_secret,
             :telephony_ring_timeout_seconds,
             :telephony_max_duration_seconds
           ] ->
        {:error, :telephony_provider_unavailable}

      _ ->
        {:error, :invalid_provider_webhook}
    end
  end

  def verify(_, _), do: {:error, :invalid_provider_webhook}

  defp token("Bearer " <> token), do: token(token)

  defp token(token) when byte_size(token) in 1..8_192 do
    if String.trim(token) == token, do: {:ok, token}, else: {:error, :invalid_token}
  end

  defp token(_), do: {:error, :invalid_token}

  defp decode_json(value) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(bytes) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp valid_times?(claims) do
    now = System.system_time(:second)

    is_integer(claims["exp"]) and claims["exp"] > now and
      (is_nil(claims["nbf"]) or (is_integer(claims["nbf"]) and claims["nbf"] <= now + 5))
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_compare(_, _), do: false
end
