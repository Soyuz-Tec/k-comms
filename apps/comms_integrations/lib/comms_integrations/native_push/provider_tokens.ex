defmodule CommsIntegrations.NativePush.ProviderTokens do
  @moduledoc false
  @oauth_url "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/firebase.messaging"
  def apns_configured? do
    config = config(:native_push_apns)
    valid_id?(config[:key_id]) && valid_id?(config[:team_id]) &&
      case private_key(config[:private_key_file]) do {:ok, key} -> ec_p256?(key); _ -> false end
  end
  def fcm_configured? do
    with {:ok, bytes} <- bounded_read(config(:native_push_fcm)[:service_account_file]),
         {:ok, %{"type" => "service_account", "project_id" => project, "client_email" => email, "private_key" => pem}} <- Jason.decode(bytes),
         true <- is_binary(project) && Regex.match?(~r/^[a-z][a-z0-9-]{4,62}$/, project),
         true <- is_binary(email) && Regex.match?(~r/^[A-Za-z0-9_.\-]+@[A-Za-z0-9.\-]+\.gserviceaccount\.com$/, email),
         {:ok, key} <- pem_key(pem), true <- is_tuple(key) && elem(key, 0) == :RSAPrivateKey do true
    else _ -> false end
  rescue
    _ -> false
  end
  def apns do
    config = config(:native_push_apns)
    with true <- apns_configured?(), {:ok, key} <- private_key(config[:private_key_file]),
         true <- ec_p256?(key),
         input <- encode(%{"alg" => "ES256", "kid" => config[:key_id]}) <> "." <>
           encode(%{"iss" => config[:team_id], "iat" => System.system_time(:second)}),
         {_, r, s} <- :public_key.der_decode(:"ECDSA-Sig-Value", :public_key.sign(input, :sha256, key)),
         true <- is_integer(r) && is_integer(s) && r >= 0 && s >= 0 && r < Integer.pow(2, 256) && s < Integer.pow(2, 256) do
      {:ok, input <> "." <> Base.url_encode64(<<r::unsigned-big-size(256), s::unsigned-big-size(256)>>, padding: false)}
    else
      _ -> {:error, :native_push_credentials_unavailable}
    end
  rescue
    _ -> {:error, :native_push_credentials_unavailable}
  end
  def fcm(deadline) do
    with {:ok, bytes} <- bounded_read(config(:native_push_fcm)[:service_account_file]),
         {:ok, %{"type" => "service_account", "project_id" => project, "client_email" => email,
                  "private_key" => pem}} <- Jason.decode(bytes),
         true <- is_binary(project) && Regex.match?(~r/^[a-z][a-z0-9-]{4,62}$/, project),
         true <- is_binary(email) && Regex.match?(~r/^[A-Za-z0-9_.\-]+@[A-Za-z0-9.\-]+\.gserviceaccount\.com$/, email),
         {:ok, key} <- pem_key(pem), true <- is_tuple(key) && elem(key, 0) == :RSAPrivateKey,
         timestamp <- System.system_time(:second),
         input <- encode(%{"alg" => "RS256", "typ" => "JWT"}) <> "." <>
           encode(%{"iss" => email, "scope" => @scope, "aud" => @oauth_url, "iat" => timestamp, "exp" => timestamp + 300}),
         assertion <- input <> "." <> Base.url_encode64(:public_key.sign(input, :sha256, key), padding: false),
         timeout <- min(max(deadline - System.monotonic_time(:millisecond), 0), 1_000), true <- timeout > 0,
         {:ok, %{status: 200, body: body}} <- CommsIntegrations.PinnedHttp.request(:post, @oauth_url,
           [{"content-type", "application/x-www-form-urlencoded"}],
           URI.encode_query(%{"grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion" => assertion}),
           allowed_hosts: ["oauth2.googleapis.com"], timeout_ms: timeout, max_response_bytes: 8_192),
         {:ok, %{"access_token" => token, "token_type" => "Bearer", "expires_in" => ttl}} <- Jason.decode(body),
         true <- is_binary(token) && byte_size(token) in 1..8_192 && is_integer(ttl) && ttl > 0 &&
           not String.contains?(token, ["\r", "\n"]) do
      {:ok, project, token}
    else
      _ -> {:error, :native_push_credentials_unavailable}
    end
  rescue
    _ -> {:error, :native_push_credentials_unavailable}
  end
  defp ec_p256?(key), do: is_tuple(key) && elem(key, 0) == :ECPrivateKey &&
    Enum.any?(Tuple.to_list(key), &(&1 == {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}))
  defp private_key(path), do: with({:ok, bytes} <- bounded_read(path), do: pem_key(bytes))
  defp pem_key(bytes) when is_binary(bytes) do
    case :public_key.pem_decode(bytes) do
      [entry] -> {:ok, :public_key.pem_entry_decode(entry)}
      _ -> {:error, :native_push_credentials_unavailable}
    end
  end
  defp pem_key(_), do: {:error, :native_push_credentials_unavailable}
  # Production reads have a fixed root. No environment variable can widen it.
  # Root mounts must themselves be operator-owned, private directories.
  @doc false
  def private_file?(path, root) when is_binary(path) and is_binary(root) do
    direct = Path.dirname(path) == root && Path.expand(path) == path && Path.basename(path) not in [".", ".."]
    case File.lstat(path) do
      {:ok, stat} -> direct && stat.type == :regular && stat.size in 1..16_384 &&
        Bitwise.band(stat.mode, 0o777) in [0o400, 0o600] && Bitwise.band(stat.mode, 0o7000) == 0
      _ -> false
    end
  end
  def private_file?(_, _), do: false
  defp bounded_read(path) when is_binary(path) do
    with true <- private_file?(path, "/run/secrets"),
         {:ok, bytes} <- File.read(path), true <- byte_size(bytes) in 1..16_384 do {:ok, bytes}
    else _ -> {:error, :native_push_credentials_unavailable} end
  end
  defp bounded_read(_), do: {:error, :native_push_credentials_unavailable}
  defp valid_id?(value), do: is_binary(value) && Regex.match?(~r/^[A-Z0-9]{10}$/, value)
  defp config(key), do: Application.get_env(:comms_integrations, key, [])
  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
end
