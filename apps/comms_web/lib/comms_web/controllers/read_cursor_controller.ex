defmodule CommsWeb.ReadCursorController do
  use CommsWeb, :controller

  alias CommsCore.Conversations
  alias CommsWeb.Broadcast

  def update(conn, %{"conversation_id" => id, "sequence" => sequence}) do
    with {:ok, stored} <-
           Conversations.mark_read(id, parse_integer(sequence), conn.assigns.current_subject) do
      payload = %{user_id: conn.assigns.current_subject.user_id, sequence: stored}
      Broadcast.event(id, "conversation.read.v1", payload)
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
