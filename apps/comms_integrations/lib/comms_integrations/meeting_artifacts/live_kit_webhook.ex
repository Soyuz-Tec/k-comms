defmodule CommsIntegrations.MeetingArtifacts.LiveKitWebhook do
  @moduledoc "Verifies LiveKit Egress callbacks against the exact raw request bytes."

  alias CommsIntegrations.MeetingArtifacts.Config

  @maximum_body_bytes 262_144

  def verify(body, authorization)
      when is_binary(body) and byte_size(body) <= @maximum_body_bytes and is_binary(authorization) do
    with {:ok, config} <- Config.control_configuration(),
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
      {:error, :artifact_provider_unavailable} = error -> error
      _ -> {:error, :invalid_provider_webhook}
    end
  end

  def verify(_, _), do: {:error, :invalid_provider_webhook}

  def sign(claims, secret) do
    header = encode_segment(%{"alg" => "HS256", "typ" => "JWT"})
    payload = encode_segment(claims)
    input = header <> "." <> payload
    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, input), padding: false)
  end

  defp token("Bearer " <> value), do: token(value)

  defp token(value) when byte_size(value) in 1..8_192 do
    if String.trim(value) == value, do: {:ok, value}, else: {:error, :invalid_token}
  end

  defp token(_), do: {:error, :invalid_token}

  defp encode_segment(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

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
