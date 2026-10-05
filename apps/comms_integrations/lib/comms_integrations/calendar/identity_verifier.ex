defmodule CommsIntegrations.Calendar.IdentityVerifier do
  @moduledoc false
  alias CommsIntegrations.Calendar.Config
  alias CommsCore.AudioCalls.CalendarSync.ExternalIdentityReceipt

  def verify(token, %{"keys" => keys}, %Config{} = config, nonce)
      when is_binary(token) and byte_size(token) in 1..32_768 and is_list(keys) and
             length(keys) in 1..20 and is_binary(nonce) and byte_size(nonce) in 32..256 do
    {_, header} = token |> JOSE.JWT.peek_protected() |> JOSE.JWS.to_map()
    matching = Enum.filter(keys, &(is_map(&1) and &1["kid"] == header["kid"]))

    with true <- header["alg"] == "RS256" and bounded?(header["kid"], 1, 256),
         true <- Enum.all?(["jku", "x5u", "crit", "b64"], &is_nil(header[&1])),
         [key] <- matching,
         true <-
           key["kty"] == "RSA" and key["use"] in [nil, "sig"] and key["alg"] in [nil, "RS256"],
         true <- key["key_ops"] in [nil, ["verify"]],
         {:ok, modulus} <- Base.url_decode64(key["n"], padding: false),
         true <- byte_size(modulus) >= 256 and :binary.first(modulus) != 0,
         true <- byte_size(modulus) > 256 or :binary.first(modulus) >= 128,
         {true, jwt, _} <- JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token),
         claims = jwt.fields,
         now = System.system_time(:second),
         true <- valid_issuer?(claims["iss"], config),
         true <- claims["aud"] == config.client_id or claims["aud"] == [config.client_id],
         true <- is_nil(claims["azp"]) or claims["azp"] == config.client_id,
         true <- bounded?(claims["sub"], 1, 512),
         true <- is_integer(claims["exp"]) and claims["exp"] > now and claims["exp"] <= now + 3600,
         true <-
           is_integer(claims["iat"]) and claims["iat"] <= now + 30 and claims["iat"] >= now - 3600,
         true <- is_nil(claims["nbf"]) or (is_integer(claims["nbf"]) and claims["nbf"] <= now),
         true <- secure_equal?(claims["nonce"], nonce),
         {:ok, subject} <- external_subject(claims, config) do
      {:ok,
       %ExternalIdentityReceipt{
         provider: config.provider,
         external_subject: subject,
         oidc_subject: claims["sub"]
       }}
    else
      _ -> {:error, :invalid_calendar_provider_identity}
    end
  rescue
    _ -> {:error, :invalid_calendar_provider_identity}
  end

  def verify(_, _, _, _), do: {:error, :invalid_calendar_provider_identity}

  defp valid_issuer?(issuer, %Config{provider: :google}),
    do: issuer in ["https://accounts.google.com", "accounts.google.com"]

  defp valid_issuer?(issuer, %Config{} = config), do: issuer == Config.endpoints(config).issuer

  defp external_subject(claims, %Config{provider: :google}), do: {:ok, claims["sub"]}

  defp external_subject(claims, %Config{provider: :microsoft, tenant_id: tenant}) do
    with true <- claims["tid"] == tenant,
         {:ok, oid} <- Ecto.UUID.cast(claims["oid"]) do
      {:ok, tenant <> ":" <> oid}
    else
      _ -> {:error, :invalid_calendar_provider_identity}
    end
  end

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_equal?(_, _), do: false

  defp bounded?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and
        Regex.match?(~r/\A[\x21-\x7e]+\z/, value)
end
