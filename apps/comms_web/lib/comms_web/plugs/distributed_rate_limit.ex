defmodule CommsWeb.Plugs.DistributedRateLimit do
  @moduledoc """
  Enforces a cluster-wide public-mutation limit after the node-local limiter.

  By default, the client network is resolved through the trusted-proxy policy,
  normalized to IPv4 /32 or IPv6 /64, and HMACed before it crosses into the
  core/database boundary. The instant-room conversion pipeline may opt into an
  authenticated tenant/user/session key after authentication; those identifiers
  are also HMACed and are never persisted in raw form.

  A dedicated `:public_rate_limit_privacy_key` application setting is preferred;
  otherwise a domain-separated key is derived from the configured endpoint
  secret.
  """

  import Plug.Conn

  alias CommsCore.PlatformRateLimits
  alias CommsWeb.Plugs.TrustedProxy

  @scopes [
    :instant_room_create,
    :instant_room_join,
    :instant_room_conversion,
    :instant_room_message
  ]
  @key_sources [:client_network, :authenticated_subject]
  @key_derivation_context "k-comms:public-rate-limit:privacy-key:v1"
  @authenticated_subject_context "authenticated-subject:v1"

  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)
    limit = Keyword.fetch!(opts, :limit)
    window = Keyword.fetch!(opts, :window)
    configured_key = Keyword.get(opts, :privacy_key)
    key_source = Keyword.get(opts, :key_source, :client_network)

    unless scope in @scopes do
      raise ArgumentError, "unsupported distributed public rate limit scope"
    end

    unless is_integer(limit) and limit > 0 and is_integer(window) and window > 0 do
      raise ArgumentError, "distributed public rate limit/window must be positive integers"
    end

    unless key_source in @key_sources do
      raise ArgumentError, "unsupported distributed public rate limit key source"
    end

    if key_source == :authenticated_subject and scope != :instant_room_conversion do
      raise ArgumentError,
            "authenticated subject rate limiting is only supported for instant-room conversion"
    end

    if configured_key != nil do
      validate_privacy_key!(configured_key)
    end

    [
      scope: scope,
      limit: limit,
      window: window,
      privacy_key: configured_key,
      key_source: key_source
    ]
  end

  def call(%Plug.Conn{} = conn, opts) do
    scope = Keyword.fetch!(opts, :scope)
    limit = Keyword.fetch!(opts, :limit)
    window = Keyword.fetch!(opts, :window)

    key_digest =
      rate_limit_key_digest(
        conn,
        scope,
        Keyword.fetch!(opts, :key_source),
        Keyword.get(opts, :privacy_key)
      )

    decision = PlatformRateLimits.allow?(scope, key_digest, limit, window)

    if decision.allowed do
      conn
    else
      reject(conn, decision.retry_after)
    end
  end

  @doc """
  HMACs trusted identity material for one supported public-mutation scope.

  Callers must supply only bounded, already-selected identity material. The
  configured privacy key and scope domain separation match the HTTP client
  network path exactly.
  """
  @spec key_digest(atom(), iodata(), keyword()) :: binary()
  def key_digest(scope, material, opts \\ []) do
    unless scope in @scopes do
      raise ArgumentError, "unsupported distributed public rate limit scope"
    end

    scoped_material =
      IO.iodata_to_binary([
        Atom.to_string(scope),
        0,
        material
      ])

    :crypto.mac(
      :hmac,
      :sha256,
      privacy_key(Keyword.get(opts, :privacy_key)),
      scoped_material
    )
  end

  defp client_key_digest(conn, scope, configured_key) do
    address =
      TrustedProxy.client_address(
        conn.remote_ip,
        get_req_header(conn, "x-forwarded-for")
      )

    key_digest(scope, normalized_address(address), privacy_key: configured_key)
  end

  defp rate_limit_key_digest(conn, scope, :client_network, configured_key),
    do: client_key_digest(conn, scope, configured_key)

  defp rate_limit_key_digest(conn, scope, :authenticated_subject, configured_key) do
    with subject when is_map(subject) <- conn.assigns[:current_subject],
         {:ok, tenant_id} <- subject_identifier(subject, :tenant_id),
         {:ok, user_id} <- subject_identifier(subject, :user_id),
         {:ok, session_id} <- subject_identifier(subject, :session_id) do
      key_digest(
        scope,
        [
          @authenticated_subject_context,
          length_prefixed(tenant_id),
          length_prefixed(user_id),
          length_prefixed(session_id)
        ],
        privacy_key: configured_key
      )
    else
      _ ->
        raise ArgumentError,
              "authenticated subject rate limiting requires tenant, user, and session identifiers"
    end
  end

  defp subject_identifier(subject, key) do
    case Map.get(subject, key) || Map.get(subject, Atom.to_string(key)) do
      value when is_binary(value) and byte_size(value) in 1..128 -> {:ok, value}
      _ -> :error
    end
  end

  defp length_prefixed(value), do: [<<byte_size(value)::unsigned-big-16>>, value]

  defp normalized_address({a, b, c, d})
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    <<4, 32, a, b, c, d>>
  end

  defp normalized_address({0, 0, 0, 0, 0, 0xFFFF, high, low})
       when high in 0..65_535 and low in 0..65_535 do
    <<4, 32, high::16, low::16>>
  end

  defp normalized_address({a, b, c, d, e, f, g, h})
       when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and
              d in 0..65_535 and e in 0..65_535 and f in 0..65_535 and
              g in 0..65_535 and h in 0..65_535 do
    <<6, 64, a::16, b::16, c::16, d::16>>
  end

  defp normalized_address(_address), do: <<0>>

  defp privacy_key(configured_key) when is_binary(configured_key) do
    validate_privacy_key!(configured_key)
  end

  defp privacy_key(nil) do
    case Application.get_env(:comms_web, :public_rate_limit_privacy_key) do
      key when is_binary(key) ->
        validate_privacy_key!(key)

      nil ->
        endpoint_secret =
          :comms_web
          |> Application.fetch_env!(CommsWeb.Endpoint)
          |> Keyword.fetch!(:secret_key_base)
          |> validate_privacy_key!()

        :crypto.mac(:hmac, :sha256, endpoint_secret, @key_derivation_context)

      _other ->
        raise ArgumentError, "public rate limit privacy key must be a binary"
    end
  end

  defp validate_privacy_key!(key) when is_binary(key) and byte_size(key) >= 32, do: key

  defp validate_privacy_key!(_key) do
    raise ArgumentError, "public rate limit privacy key must contain at least 32 bytes"
  end

  defp reject(conn, retry_after) do
    retry_after = max(retry_after, 1)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        error: %{
          code: "rate_limited",
          detail: "Too many requests",
          retry_after: retry_after
        }
      })
    )
    |> halt()
  end
end
