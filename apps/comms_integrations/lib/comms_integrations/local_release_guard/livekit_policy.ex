defmodule CommsIntegrations.LocalReleaseGuard.LiveKitPolicy do
  @moduledoc false

  alias CommsIntegrations.LocalReleaseGuard.OriginPolicy

  @local_topology "local_sidecar"
  @managed_topology "managed_cloud"
  @managed_confirmation "livekit-cloud-v1"

  def validate_topology!(@local_topology, confirmation) when confirmation in [nil, ""], do: :ok

  def validate_topology!(@local_topology, _confirmation) do
    raise ArgumentError,
          "K_COMMS_MANAGED_LIVEKIT_CONFIRMATION is valid only when " <>
            "K_COMMS_LIVEKIT_TOPOLOGY=#{@managed_topology}"
  end

  def validate_topology!(@managed_topology, @managed_confirmation), do: :ok

  def validate_topology!(@managed_topology, _confirmation) do
    raise ArgumentError,
          "K_COMMS_MANAGED_LIVEKIT_CONFIRMATION must exactly equal " <>
            @managed_confirmation
  end

  def validate_topology!(_topology, _confirmation) do
    raise ArgumentError,
          "K_COMMS_LIVEKIT_TOPOLOGY must be exactly " <>
            "#{@local_topology} or #{@managed_topology}"
  end

  def require_topology_origins!(options, @local_topology, public_hosts) do
    OriginPolicy.require_origin!(
      Keyword.fetch!(options, :livekit_server_url),
      "LIVEKIT_SERVER_URL",
      ["ws"],
      public_hosts
    )

    OriginPolicy.require_origin!(
      Keyword.fetch!(options, :livekit_api_url),
      "LIVEKIT_API_URL",
      ["http"],
      ["livekit"],
      required_port: 7880
    )

    nil
  end

  def require_topology_origins!(options, @managed_topology, _public_hosts) do
    livekit_origin =
      OriginPolicy.require_public_origin!(
        Keyword.fetch!(options, :livekit_server_url),
        "LIVEKIT_SERVER_URL",
        "wss"
      )

    require_api_origin!(
      Keyword.fetch!(options, :livekit_api_url),
      livekit_origin,
      @managed_topology
    )

    livekit_origin
  end

  def require_api_origin!(value, _livekit_origin, @local_topology) do
    OriginPolicy.require_origin!(
      value,
      "LIVEKIT_API_URL",
      ["http"],
      ["livekit"],
      required_port: 7880
    )
  end

  def require_api_origin!(value, {_scheme, livekit_host, _port}, @managed_topology) do
    case OriginPolicy.require_public_origin!(value, "LIVEKIT_API_URL", "https") do
      {"https", ^livekit_host, 443} ->
        :ok

      _ ->
        raise ArgumentError,
              "LIVEKIT_API_URL must use the same public host as " <>
                "LIVEKIT_SERVER_URL in managed-cloud mode"
    end
  end

  def require_managed_csp!(values, livekit_origin, public_hosts) do
    {livekit_values, local_values} =
      Enum.split_with(values, fn value ->
        OriginPolicy.origin_identity(value, "wss") == {:ok, livekit_origin}
      end)

    unless length(livekit_values) == 1 do
      raise ArgumentError,
            "CSP_CONNECT_SOURCES must contain LIVEKIT_SERVER_URL exactly once " <>
              "in managed-cloud mode"
    end

    OriginPolicy.require_origin_list!(
      local_values,
      "CSP_CONNECT_SOURCES",
      ["http", "ws"],
      public_hosts
    )
  end
end
