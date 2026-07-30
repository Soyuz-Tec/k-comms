defmodule CommsIntegrations.LocalReleaseGuard do
  @moduledoc """
  Fail-closed validation facade for the packaged qualification runtime.

  Profile-specific policy lives under `CommsIntegrations.LocalReleaseGuard`.
  """

  alias CommsIntegrations.LocalReleaseGuard.{
    DirectRelease,
    LiveKitPolicy,
    QualificationAppPolicy,
    TrustedEdge
  }

  @trusted_edge_exposure_mode "cloudflare_trusted_edge"
  @local_livekit_topology "local_sidecar"

  @spec validate!(keyword()) :: :ok
  def validate!(options) do
    enabled? = Keyword.fetch!(options, :enabled?)
    exposure_mode = Keyword.get(options, :exposure_mode)
    trusted_edge_confirmation = Keyword.get(options, :trusted_edge_confirmation)
    livekit_topology = Keyword.get(options, :livekit_topology, @local_livekit_topology)
    managed_livekit_confirmation = Keyword.get(options, :managed_livekit_confirmation)

    LiveKitPolicy.validate_topology!(livekit_topology, managed_livekit_confirmation)

    unless exposure_mode in [nil, "", @trusted_edge_exposure_mode] do
      raise ArgumentError,
            "K_COMMS_RELEASE_EXPOSURE_MODE must be unset or exactly " <>
              @trusted_edge_exposure_mode
    end

    cond do
      exposure_mode == @trusted_edge_exposure_mode and not enabled? ->
        raise ArgumentError,
              "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode} requires " <>
                "K_COMMS_LOCAL_RELEASE=true"

      enabled? ->
        validate_enabled!(
          options,
          exposure_mode,
          trusted_edge_confirmation,
          livekit_topology
        )

      QualificationAppPolicy.requested?(options) ->
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires K_COMMS_LOCAL_RELEASE=true"

      trusted_edge_confirmation not in [nil, ""] ->
        raise ArgumentError,
              "K_COMMS_TRUSTED_EDGE_CONFIRMATION is valid only when " <>
                "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode}"

      true ->
        :ok
    end

    :ok
  end

  defp validate_enabled!(
         options,
         exposure_mode,
         trusted_edge_confirmation,
         livekit_topology
       ) do
    unless Keyword.fetch!(options, :development_adapters?) do
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE=true requires ALLOW_DEVELOPMENT_ADAPTERS=true"
    end

    unless Keyword.fetch!(options, :runtime_purpose) == "application" do
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE=true is valid only for an application runtime"
    end

    unless Keyword.fetch!(options, :audio_provider_mode) == "livekit" do
      raise ArgumentError,
            "K_COMMS_LOCAL_RELEASE=true requires AUDIO_PROVIDER_MODE=livekit"
    end

    if exposure_mode == @trusted_edge_exposure_mode do
      TrustedEdge.validate!(
        options,
        trusted_edge_confirmation,
        livekit_topology
      )
    else
      unless trusted_edge_confirmation in [nil, ""] do
        raise ArgumentError,
              "K_COMMS_TRUSTED_EDGE_CONFIRMATION is valid only when " <>
                "K_COMMS_RELEASE_EXPOSURE_MODE=#{@trusted_edge_exposure_mode}"
      end

      DirectRelease.validate!(options, livekit_topology)
    end
  end
end
