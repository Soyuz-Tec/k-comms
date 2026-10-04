defmodule CommsIntegrations.Telephony do
  @moduledoc "Server-only SIP control plane. Disabled until explicitly configured."

  alias CommsIntegrations.Telephony.LiveKit

  def enabled?, do: mode() in ["livekit", :livekit]
  def ready?, do: enabled?() and LiveKit.configured?()

  def status do
    %{
      enabled: enabled?(),
      configured: ready?(),
      provider: if(enabled?(), do: "livekit", else: "disabled")
    }
  end

  def create_outbound(command) do
    if ready?(), do: adapter().create_outbound(command), else: unavailable()
  end

  def get_participant(room, identity) do
    adapter().get_participant(room, identity)
  end

  def end_call(room) do
    adapter().end_call(room)
  end

  defp mode, do: Application.get_env(:comms_integrations, :telephony_provider_mode, "disabled")

  defp adapter,
    do: Application.get_env(:comms_integrations, :telephony_adapter, LiveKit)

  defp unavailable, do: {:error, :telephony_provider_unavailable}
end
