defmodule CommsIntegrations.LocalReleaseGuard.TrustedEdge do
  @moduledoc false

  alias CommsIntegrations.LocalReleaseGuard.{
    LiveKitPolicy,
    OriginPolicy,
    QualificationAppPolicy
  }

  @exposure_mode "cloudflare_trusted_edge"
  @confirmation "cloudflare-tunnel-v1"

  def validate!(options, confirmation, livekit_topology) do
    unless confirmation == @confirmation do
      raise ArgumentError,
            "K_COMMS_TRUSTED_EDGE_CONFIRMATION must exactly equal " <>
              @confirmation
    end

    if QualificationAppPolicy.requested?(options) do
      raise ArgumentError,
            "K_COMMS_QUALIFICATION_APP_ORIGIN is not valid with " <>
              "K_COMMS_RELEASE_EXPOSURE_MODE=#{@exposure_mode}"
    end

    public_app_url = Keyword.fetch!(options, :public_app_url)

    public_app_origin =
      OriginPolicy.require_public_origin!(
        public_app_url,
        "PUBLIC_APP_URL",
        "https"
      )

    phx_host =
      options
      |> Keyword.fetch!(:phx_host)
      |> OriginPolicy.normalize_hostname!("PHX_HOST")

    unless elem(public_app_origin, 1) == phx_host do
      raise ArgumentError,
            "PHX_HOST must exactly match the PUBLIC_APP_URL host in trusted-edge mode"
    end

    livekit_origin =
      OriginPolicy.require_public_origin!(
        Keyword.fetch!(options, :livekit_server_url),
        "LIVEKIT_SERVER_URL",
        "wss"
      )

    LiveKitPolicy.require_api_origin!(
      Keyword.fetch!(options, :livekit_api_url),
      livekit_origin,
      livekit_topology
    )

    object_origin =
      OriginPolicy.require_public_origin!(
        Keyword.fetch!(options, :s3_public_endpoint),
        "S3_PUBLIC_ENDPOINT",
        "https"
      )

    require_exact_cors!(
      Keyword.fetch!(options, :cors_origins),
      public_app_url
    )

    require_exact_csp!(
      Keyword.fetch!(options, :csp_connect_sources),
      livekit_origin,
      object_origin
    )

    unless Keyword.get(options, :hsts?, false) do
      raise ArgumentError,
            "HSTS_ENABLED must be true when " <>
              "K_COMMS_RELEASE_EXPOSURE_MODE=#{@exposure_mode}"
    end

    require_exact_trusted_proxy_cidr!(Keyword.get(options, :trusted_proxy_cidrs, []))
  end

  defp require_exact_cors!(values, public_app_url) do
    unless values == [public_app_url] do
      raise ArgumentError,
            "CORS_ORIGINS must contain exactly PUBLIC_APP_URL in trusted-edge mode"
    end
  end

  defp require_exact_csp!(values, livekit_origin, object_origin) do
    valid? =
      case values do
        ["'self'", livekit, object] ->
          OriginPolicy.origin_identity(livekit, "wss") == {:ok, livekit_origin} and
            OriginPolicy.origin_identity(object, "https") == {:ok, object_origin}

        _ ->
          false
      end

    unless valid? do
      raise ArgumentError,
            "CSP_CONNECT_SOURCES must contain exactly 'self', LIVEKIT_SERVER_URL, " <>
              "and S3_PUBLIC_ENDPOINT in trusted-edge mode"
    end
  end

  defp require_exact_trusted_proxy_cidr!([value]) do
    unless OriginPolicy.canonical_private_ipv4_host_cidr?(value) do
      raise ArgumentError,
            "TRUSTED_PROXY_CIDRS must contain exactly one canonical private IPv4 /32 " <>
              "in trusted-edge mode"
    end
  end

  defp require_exact_trusted_proxy_cidr!(_values) do
    raise ArgumentError,
          "TRUSTED_PROXY_CIDRS must contain exactly one canonical private IPv4 /32 " <>
            "in trusted-edge mode"
  end
end
