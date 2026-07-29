defmodule CommsIntegrations.Audio.IceServers do
  @moduledoc """
  Builds the ICE server list handed to a browser alongside its participant
  credential.

  Without a relay, a participant behind a symmetric NAT or a UDP-blocking
  corporate firewall cannot establish media at all, so the call fails rather
  than degrades. TURN gives those participants a relayed path.

  TURN credentials are derived per participant with the coturn REST scheme
  (`use-auth-secret`): the username carries its own expiry, and the password is
  an HMAC of that username under a shared secret. The browser therefore never
  receives a durable TURN password, matching the short-lived participant tokens
  already issued for the media plane.
  """

  @minimum_ttl_seconds 60
  @maximum_ttl_seconds 86_400
  @default_ttl_seconds 3_600

  @doc """
  Returns the ICE servers for a participant identity.

  An empty list is a valid, non-error result: it means no relay is configured,
  which is the portable default for local and single-host deployments.
  """
  def for_participant(identity) when is_binary(identity) and identity != "" do
    with {:ok, stun_urls} <- validated_urls(configured(:stun_urls), [:stun]),
         {:ok, turn_urls} <- validated_urls(configured(:turn_urls), [:turn, :turns]) do
      cond do
        turn_urls == [] and stun_urls == [] -> {:ok, []}
        turn_urls == [] -> {:ok, [%{urls: stun_urls}]}
        true -> relay_servers(stun_urls, turn_urls, identity)
      end
    end
  end

  def for_participant(_identity), do: {:error, :audio_identity_invalid}

  @doc """
  Reports relay configuration for status endpoints without exposing secrets.
  """
  def status do
    case for_participant("status-probe") do
      {:ok, []} ->
        %{status: :unconfigured, relay: false}

      {:ok, servers} ->
        %{status: :available, relay: Enum.any?(servers, &Map.has_key?(&1, :username))}

      {:error, reason} ->
        %{status: :invalid, reason: reason}
    end
  end

  defp relay_servers(stun_urls, turn_urls, identity) do
    with {:ok, secret} <- required_secret(),
         {:ok, ttl} <- credential_ttl() do
      expiry = System.system_time(:second) + ttl
      username = "#{expiry}:#{identity}"

      # coturn's REST scheme specifies HMAC-SHA1 over the username. The SHA-1 is
      # a keyed MAC here, not a collision-sensitive digest, and the algorithm is
      # fixed by the TURN server rather than chosen here.
      credential =
        :hmac
        |> :crypto.mac(:sha, secret, username)
        |> Base.encode64()

      relay = %{urls: turn_urls, username: username, credential: credential}

      {:ok, if(stun_urls == [], do: [relay], else: [%{urls: stun_urls}, relay])}
    end
  end

  defp required_secret do
    case configured(:turn_static_auth_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 16 -> {:ok, secret}
      nil -> {:error, :turn_static_auth_secret_missing}
      "" -> {:error, :turn_static_auth_secret_missing}
      _ -> {:error, :turn_static_auth_secret_too_short}
    end
  end

  defp credential_ttl do
    case configured(:turn_credential_ttl_seconds) || @default_ttl_seconds do
      ttl when is_integer(ttl) and ttl >= @minimum_ttl_seconds and ttl <= @maximum_ttl_seconds ->
        {:ok, ttl}

      _ ->
        {:error, :turn_credential_ttl_invalid}
    end
  end

  defp validated_urls(nil, _permitted), do: {:ok, []}
  defp validated_urls([], _permitted), do: {:ok, []}

  defp validated_urls(urls, permitted) when is_list(urls) do
    Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, acc} ->
      case validated_url(url, permitted) do
        {:ok, valid} -> {:cont, {:ok, acc ++ [valid]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validated_urls(_urls, _permitted), do: {:error, :ice_server_url_invalid}

  defp validated_url(url, permitted) when is_binary(url) do
    trimmed = String.trim(url)

    with {:ok, scheme, host} <- parse_ice_url(trimmed),
         :ok <- validate_permitted(scheme, permitted),
         :ok <- validate_host(host),
         :ok <- validate_scheme_security(scheme) do
      {:ok, trimmed}
    end
  end

  defp validated_url(_url, _permitted), do: {:error, :ice_server_url_invalid}

  defp validate_permitted(scheme, permitted) do
    if scheme in permitted, do: :ok, else: {:error, :ice_server_scheme_invalid}
  end

  defp validate_host(host) when is_binary(host) and host != "", do: :ok
  defp validate_host(_host), do: {:error, :ice_server_host_missing}

  # ICE URLs are not standard URIs: the host section is followed by optional
  # `?transport=` rather than a path, so they are split explicitly instead of
  # being handed to URI.parse/1.
  defp parse_ice_url(url) do
    case String.split(url, ":", parts: 2) do
      [scheme, rest] when rest != "" ->
        host =
          rest
          |> String.split("?", parts: 2)
          |> List.first()
          |> String.split(":", parts: 2)
          |> List.first()

        case scheme do
          "stun" -> {:ok, :stun, host}
          "stuns" -> {:ok, :stuns, host}
          "turn" -> {:ok, :turn, host}
          "turns" -> {:ok, :turns, host}
          _ -> {:error, :ice_server_scheme_invalid}
        end

      _ ->
        {:error, :ice_server_url_invalid}
    end
  end

  # A plaintext `turn:` relay carries the derived credential in the clear and is
  # the first thing a restrictive network blocks, so promoted environments must
  # use `turns:`. STUN carries no credential and stays permitted either way.
  defp validate_scheme_security(:turn) do
    if allow_insecure_local_media?(), do: :ok, else: {:error, :insecure_turn_endpoint}
  end

  defp validate_scheme_security(_scheme), do: :ok

  defp allow_insecure_local_media? do
    Application.get_env(:comms_integrations, :allow_insecure_local_media, false) == true
  end

  defp configured(key), do: Application.get_env(:comms_integrations, key)
end
