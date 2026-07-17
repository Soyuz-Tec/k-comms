defmodule CommsIntegrations.Audio.RoomService do
  def delete_room(call) when is_map(call), do: adapter().delete_room(call)

  def remove_participant(call, identity) when is_map(call) and is_binary(identity),
    do: adapter().remove_participant(call, identity)

  defp adapter do
    Application.get_env(
      :comms_integrations,
      :audio_room_service_adapter,
      CommsIntegrations.Audio.LiveKitRoomService
    )
  end
end
