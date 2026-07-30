defmodule CommsCore.Conversations.AvailabilityQuery do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Conversations.{EphemeralPresenceLease, EphemeralRoom}

  def unavailable_ephemeral_conversation_ids(timestamp) do
    live_presence =
      from(lease in EphemeralPresenceLease,
        where:
          lease.ephemeral_room_id == parent_as(:ephemeral_room).id and
            is_nil(lease.closed_at) and lease.expires_at > ^timestamp,
        select: 1
      )

    from(room in EphemeralRoom,
      as: :ephemeral_room,
      where:
        room.status == :expired or not is_nil(room.expired_at) or
          (room.status == :idle and
             (is_nil(room.expires_at) or room.expires_at <= ^timestamp)) or
          (room.status == :active and
             fragment(
               "COALESCE(?, ?) + (? * INTERVAL '1 second') <= ?",
               room.last_presence_at,
               room.inserted_at,
               room.reconnect_grace_seconds,
               ^timestamp
             ) and not exists(live_presence)),
      select: room.conversation_id
    )
  end
end
