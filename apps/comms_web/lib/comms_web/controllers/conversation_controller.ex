defmodule CommsWeb.ConversationController do
  use CommsWeb, :controller

  alias CommsCore.Conversations

  def index(conn, _params) do
    data =
      conn.assigns.current_subject
      |> Conversations.list_for_user()
      |> Enum.map(&Presenter.conversation/1)

    json(conn, %{data: data})
  end

  def create(conn, params) do
    with {:ok, conversation} <- Conversations.create(params, conn.assigns.current_subject) do
      conn
      |> put_status(:created)
      |> json(%{data: Presenter.conversation(conversation)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, result} <- Conversations.get_for_user(id, conn.assigns.current_subject) do
      json(conn, %{data: Presenter.conversation(result)})
    end
  end

  def members(conn, %{"conversation_id" => id}) do
    with {:ok, members} <- Conversations.list_members(id, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(members, &Presenter.membership/1)})
    end
  end

  def add_member(conn, %{"conversation_id" => id, "user_id" => user_id} = params) do
    with {:ok, membership} <-
           Conversations.add_member(
             id,
             user_id,
             params["role"] || "member",
             conn.assigns.current_subject
           ) do
      CommsWeb.Broadcast.event(id, "membership.changed.v1", %{
        user_id: user_id,
        action: "added",
        role: membership.role
      })

      conn |> put_status(:created) |> json(%{data: %{id: membership.id}})
    end
  end

  def remove_member(conn, %{"conversation_id" => id, "user_id" => user_id}) do
    with {:ok, _membership} <-
           Conversations.remove_member(id, user_id, conn.assigns.current_subject) do
      CommsWeb.Broadcast.event(id, "membership.changed.v1", %{
        user_id: user_id,
        action: "removed"
      })

      send_resp(conn, :no_content, "")
    end
  end
end
