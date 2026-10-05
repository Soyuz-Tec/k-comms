defmodule CommsCore.Conversations.PrivateRoomControlPort.Contract do
  alias CommsCore.Conversations.{PrivateRoomControlCommand, PrivateRoomControlReceipt}

  @callback execute(
              :provision | :remove_member | :purge | :purge_status | :recover_room,
              PrivateRoomControlCommand.t()
            ) :: {:ok, PrivateRoomControlReceipt.t()} | {:error, atom()}
end
