defmodule CommsCore.Notifications.PushSubscriptions.Validation do
  @moduledoc false

  @subscription_format_version 1
  @max_endpoint_bytes 2_048
  @max_expiration_seconds 10 * 365 * 24 * 60 * 60

  def normalize(attrs) when is_map(attrs) do
    endpoint_value = value(attrs, :endpoint)
    keys = value(attrs, :keys)

    with {:ok, endpoint, endpoint_hint} <- validate_endpoint(endpoint_value),
         {:ok, p256dh} <-
           validate_key(value(keys || %{}, :p256dh), :p256dh),
         {:ok, auth} <- validate_key(value(keys || %{}, :auth), :auth),
         {:ok, expiration_time, expires_at} <-
           validate_expiration(value(attrs, :expiration_time)) do
      payload = %{
        "endpoint" => endpoint,
        "expirationTime" => expiration_time,
        "keys" => %{"p256dh" => p256dh, "auth" => auth},
        "version" => @subscription_format_version
      }

      {:ok,
       %{
         endpoint_hash: :crypto.hash(:sha256, endpoint),
         endpoint_hint: endpoint_hint,
         expires_at: expires_at,
         payload: payload,
         json: Jason.encode!(payload)
       }}
    end
  end

  def valid_materialized?(%{
        "version" => @subscription_format_version,
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh, "auth" => auth}
      }) do
    match?({:ok, _, _}, validate_endpoint(endpoint)) and
      match?({:ok, _}, validate_key(p256dh, :p256dh)) and
      match?({:ok, _}, validate_key(auth, :auth))
  end

  def valid_materialized?(_), do: false

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    endpoint = String.trim(endpoint)
    uri = URI.parse(endpoint)

    cond do
      endpoint == "" or byte_size(endpoint) > @max_endpoint_bytes ->
        {:error, :invalid_push_endpoint}

      Regex.match?(~r/[\x00-\x20\x7F]/, endpoint) ->
        {:error, :invalid_push_endpoint}

      String.downcase(uri.scheme || "") != "https" or
        not is_binary(uri.host) or uri.host == "" ->
        {:error, :invalid_push_endpoint}

      not is_nil(uri.userinfo) or not is_nil(uri.fragment) ->
        {:error, :invalid_push_endpoint}

      true ->
        normalized =
          uri
          |> Map.put(:scheme, "https")
          |> Map.put(:host, String.downcase(uri.host))
          |> URI.to_string()

        {:ok, normalized, String.downcase(uri.host)}
    end
  end

  defp validate_endpoint(_), do: {:error, :invalid_push_endpoint}

  defp validate_key(value, kind) when is_binary(value) do
    max_bytes = if kind == :p256dh, do: 128, else: 64

    with true <- byte_size(value) > 0 and byte_size(value) <= max_bytes,
         true <- Regex.match?(~r/^[A-Za-z0-9_-]+$/, value),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- valid_decoded_key?(decoded, kind) do
      {:ok, value}
    else
      _ -> {:error, invalid_key_error(kind)}
    end
  end

  defp validate_key(_, kind), do: {:error, invalid_key_error(kind)}
  defp valid_decoded_key?(<<4, _::binary-size(64)>>, :p256dh), do: true
  defp valid_decoded_key?(value, :auth), do: byte_size(value) == 16
  defp valid_decoded_key?(_, _), do: false
  defp invalid_key_error(:p256dh), do: :invalid_push_p256dh_key
  defp invalid_key_error(:auth), do: :invalid_push_auth_key

  defp validate_expiration(nil), do: {:ok, nil, nil}

  defp validate_expiration(value) when is_integer(value) and value > 0 do
    with {:ok, expires_at} <- DateTime.from_unix(value, :millisecond),
         true <- DateTime.compare(expires_at, now()) == :gt,
         true <-
           DateTime.diff(expires_at, now(), :second) <=
             @max_expiration_seconds do
      {:ok, value, DateTime.truncate(expires_at, :microsecond)}
    else
      _ -> {:error, :invalid_push_expiration}
    end
  end

  defp validate_expiration(_), do: {:error, :invalid_push_expiration}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
