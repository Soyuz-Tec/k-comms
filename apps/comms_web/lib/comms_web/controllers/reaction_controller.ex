defmodule CommsWeb.ReactionController do
  use CommsWeb, :controller

  alias CommsCore.Messaging
  alias CommsWeb.Broadcast

  def create(conn, %{"message_id" => message_id, "emoji" => emoji}) do
    with {:ok, _reaction} <-
           Messaging.add_reaction(message_id, emoji, conn.assigns.current_subject) do
      payload = %{
        message_id: message_id,
        emoji: emoji,
        user_id: conn.assigns.current_subject.user_id
      }

      Broadcast.event(conn.params["conversation_id"], "message.reaction_added.v1", payload)
      conn |> put_status(:created) |> json(%{data: payload})
    end
  end

  def delete(conn, %{"message_id" => message_id, "emoji" => emoji}) do
    with :ok <- Messaging.remove_reaction(message_id, emoji, conn.assigns.current_subject) do
      payload = %{
        message_id: message_id,
        emoji: emoji,
        user_id: conn.assigns.current_subject.user_id
      }

      Broadcast.event(conn.params["conversation_id"], "message.reaction_removed.v1", payload)
      send_resp(conn, :no_content, "")
    end
  end
end
