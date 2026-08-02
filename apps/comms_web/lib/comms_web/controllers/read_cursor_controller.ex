defmodule CommsWeb.ReadCursorController do
  use CommsWeb, :controller

  alias CommsCore.{Conversations, Messaging}
  alias CommsWeb.Broadcast

  def update(conn, %{"conversation_id" => id, "sequence" => sequence}) do
    subject = conn.assigns.current_subject

    with {:ok, stored} <- Conversations.mark_read(id, parse_integer(sequence), subject),
         {:ok, cursor} <- Messaging.mark_read(id, stored, subject) do
      payload = %{user_id: conn.assigns.current_subject.user_id, sequence: stored}
      Broadcast.event(id, "conversation.read.v1", payload)

      Broadcast.event(id, "message.delivery.v1", %{
        recipient_user_id: cursor.recipient_user_id,
        device_ref: cursor.device_ref,
        delivered_sequence: cursor.delivered_sequence,
        read_sequence: cursor.read_sequence,
        delivered_at: cursor.delivered_at,
        read_at: cursor.read_at
      })

      json(conn, %{data: payload})
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> -1
    end
  end

  defp parse_integer(_), do: -1
end
