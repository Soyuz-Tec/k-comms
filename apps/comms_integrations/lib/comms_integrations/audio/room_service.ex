defmodule CommsIntegrations.Audio.RoomService do
  def delete_room(provider_room) when is_binary(provider_room),
    do: adapter().delete_room(provider_room)

  def remove_participant(provider_room, identity)
      when is_binary(provider_room) and is_binary(identity),
      do: adapter().remove_participant(provider_room, identity)

  defp adapter do
    Application.get_env(
      :comms_integrations,
      :audio_room_service_adapter,
      CommsIntegrations.Audio.LiveKitRoomService
    )
  end
end
