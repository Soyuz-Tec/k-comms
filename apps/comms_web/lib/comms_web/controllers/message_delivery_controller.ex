defmodule CommsWeb.MessageDeliveryController do
  use CommsWeb, :controller

  alias CommsCore.Messaging
  alias CommsWeb.Broadcast

  def index(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, cursors} <-
           Messaging.list_delivery_cursors(conversation_id, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(cursors, &present/1)})
    end
  end

  def update(conn, %{"conversation_id" => conversation_id, "sequence" => sequence}) do
    with {:ok, cursor} <-
           Messaging.mark_delivered(
             conversation_id,
             parse_integer(sequence),
             conn.assigns.current_subject
           ) do
      payload = present(cursor)
      Broadcast.event(conversation_id, "message.delivery.v1", payload)
      json(conn, %{data: payload})
    end
  end

  defp present(cursor) do
    %{
      recipient_user_id: cursor.recipient_user_id,
      device_ref: cursor.device_ref,
      delivered_sequence: cursor.delivered_sequence,
      read_sequence: cursor.read_sequence,
      delivered_at: cursor.delivered_at,
      read_at: cursor.read_at
    }
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
