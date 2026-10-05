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

  def recording(request) do
    adapter = control_adapter()

    if function_exported?(adapter, :recording, 1),
      do: adapter.recording(request),
      else: {:error, :telephony_control_unsupported}
  end

  def wait_in_queue(command) do
    adapter = control_adapter()

    if function_exported?(adapter, :wait_in_queue, 1),
      do: adapter.wait_in_queue(command),
      else: {:error, :telephony_control_unsupported}
  end

  def resume_route(%{route_id: nil}), do: :ok

  def resume_route(command) do
    adapter = control_adapter()

    if function_exported?(adapter, :resume_route, 1),
      do: adapter.resume_route(command),
      else: {:error, :telephony_control_unsupported}
  end

  def prepare_control(command) do
    adapter = control_adapter()

    if function_exported?(adapter, :prepare_control, 1),
      do: adapter.prepare_control(command),
      else: {:ok, nil}
  end

  def execute_control(command), do: control_adapter().execute_control(command)

  defp control_adapter, do: Application.get_env(:comms_core, :telephony_control_adapter, LiveKit)

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
