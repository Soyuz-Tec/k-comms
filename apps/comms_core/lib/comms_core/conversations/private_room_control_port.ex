defmodule CommsCore.Conversations.PrivateRoomControlPort do
  alias CommsCore.Conversations.{PrivateRoomControlCommand, PrivateRoomControlReceipt}

  @spec execute(
          :provision | :remove_member | :purge | :purge_status | :recover_room,
          PrivateRoomControlCommand.t()
        ) :: {:ok, PrivateRoomControlReceipt.t()} | {:error, atom()}
  def execute(action, %PrivateRoomControlCommand{} = command)
      when action in [:provision, :remove_member, :purge, :purge_status, :recover_room] do
    with true <-
           action in [:purge, :purge_status, :recover_room] or
             Application.get_env(:comms_core, :private_rooms_enabled, false),
         {:ok, adapter} <- Application.fetch_env(:comms_core, :private_room_control_adapter),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute, 2) do
      adapter.execute(action, command)
    else
      _ -> {:error, :private_room_provider_unavailable}
    end
  end
end
