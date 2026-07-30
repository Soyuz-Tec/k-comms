defmodule CommsCore.Conversations.EphemeralRooms.Events do
  @moduledoc false

  alias CommsCore.{Audit, Outbox, Repo}

  def emit!(room, event_type, actor_user_id, payload, request_id) do
    Outbox.insert_and_enqueue!(%{
      tenant_id: room.tenant_id,
      event_type: event_type,
      aggregate_type: "ephemeral_room",
      aggregate_id: room.id,
      payload: Map.put(payload, :ephemeral_room_id, room.id),
      available_at: now()
    })

    case Audit.record(%{
           tenant_id: room.tenant_id,
           actor_user_id: actor_user_id,
           action: String.replace(event_type, ".v1", ""),
           resource_type: "conversation_ephemeral_room",
           resource_id: room.id,
           metadata: payload,
           request_id: request_id
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
