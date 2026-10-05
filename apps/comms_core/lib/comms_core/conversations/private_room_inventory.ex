defmodule CommsCore.Conversations.PrivateRoomInventory do
  import Ecto.Query

  def hazard_count do
    CommsCore.Repo.aggregate(CommsCore.Conversations.PrivateRoom, :count) +
      CommsCore.Repo.aggregate(
        from(c in CommsCore.Conversations.Conversation, where: c.content_mode == :matrix_e2ee),
        :count
      )
  end
end
