defmodule CommsIntegrations.LocalReleaseGuard.DirectRelease do
  @moduledoc false

  alias CommsIntegrations.LocalReleaseGuard.{
    LiveKitPolicy,
    OriginPolicy,
    QualificationAppPolicy
  }

  @managed_livekit_topology "managed_cloud"

  def validate!(options, livekit_topology) do
    qualification_app_origin = QualificationAppPolicy.origin!(options)
    public_hosts = OriginPolicy.release_hosts!(Keyword.fetch!(options, :local_release_host))

    OriginPolicy.require_release_hostname!(
      Keyword.fetch!(options, :phx_host),
      "PHX_HOST",
      public_hosts
    )

    OriginPolicy.require_origin!(
      Keyword.fetch!(options, :public_app_url),
      "PUBLIC_APP_URL",
      ["http"],
      public_hosts
    )

    livekit_origin =
      LiveKitPolicy.require_topology_origins!(
        options,
        livekit_topology,
        public_hosts
      )

    OriginPolicy.require_origin!(
      Keyword.fetch!(options, :s3_public_endpoint),
      "S3_PUBLIC_ENDPOINT",
      ["http"],
      public_hosts
    )

    cors_origins = Keyword.fetch!(options, :cors_origins)

    if qualification_app_origin do
      QualificationAppPolicy.require_cors!(cors_origins, qualification_app_origin)
    else
      OriginPolicy.require_origin_list!(cors_origins, "CORS_ORIGINS", ["http"], public_hosts)
    end

    csp_connect_sources =
      options
      |> Keyword.fetch!(:csp_connect_sources)
      |> Enum.reject(&(&1 == "'self'"))

    if livekit_topology == @managed_livekit_topology do
      LiveKitPolicy.require_managed_csp!(
        csp_connect_sources,
        livekit_origin,
        public_hosts
      )
    else
      OriginPolicy.require_origin_list!(
        csp_connect_sources,
        "CSP_CONNECT_SOURCES",
        ["http", "ws"],
        public_hosts
      )
    end
  end
end
