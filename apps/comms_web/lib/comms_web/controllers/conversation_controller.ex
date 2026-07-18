defmodule CommsWeb.ConversationController do
  use CommsWeb, :controller

  alias CommsCore.Conversations

  def index(conn, _params) do
    data =
      conn.assigns.current_subject
      |> Conversations.list_for_user_views()
      |> Enum.map(&Presenter.conversation/1)

    json(conn, %{data: data})
  end

  def discover_public(conn, params) do
    with {:ok, result} <-
           Conversations.discover_public_channel_views(params, conn.assigns.current_subject) do
      json(conn, %{
        data: Enum.map(result.channels, &Presenter.public_channel/1),
        page: %{
          limit: result.limit,
          has_more: result.has_more,
          next_cursor: result.next_cursor
        }
      })
    end
  end

  def join_public(conn, %{"id" => id}) do
    with {:ok, result} <-
           Conversations.join_public_channel_view(id, conn.assigns.current_subject) do
      unless result.replayed do
        CommsWeb.Broadcast.event(id, "membership.changed.v1", %{
          user_id: result.membership.user_id,
          action: "added",
          role: result.membership.role,
          version: result.membership.version,
          source: "self_service"
        })

        CommsWeb.Broadcast.conversation_membership(result.membership.user_id, id, "added")
      end

      conn
      |> put_status(if(result.replayed, do: :ok, else: :created))
      |> json(%{
        data: %{
          conversation: Presenter.conversation(result.conversation),
          membership: Presenter.membership(result.membership)
        },
        replayed: result.replayed
      })
    end
  end

  def leave_public(conn, %{"id" => id} = params) do
    with {:ok, result} <-
           Conversations.leave_public_channel_view(id, params, conn.assigns.current_subject) do
      unless result.replayed do
        CommsWeb.Broadcast.event(id, "membership.changed.v1", %{
          user_id: result.membership.user_id,
          action: "removed",
          role: result.membership.role,
          version: result.membership.version,
          source: "self_service"
        })

        CommsWeb.Broadcast.conversation_membership(result.membership.user_id, id, "removed")
      end

      json(conn, %{
        data: %{
          conversation: Presenter.conversation(result.conversation),
          membership: Presenter.membership(result.membership)
        },
        replayed: result.replayed
      })
    end
  end

  def create(conn, params) do
    with {:ok, conversation} <- Conversations.create_view(params, conn.assigns.current_subject) do
      CommsWeb.Broadcast.conversation_memberships(
        conversation.tenant_id,
        conversation.id,
        "added"
      )

      conn
      |> put_status(:created)
      |> json(%{data: Presenter.conversation(conversation)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, result} <- Conversations.get_for_user_view(id, conn.assigns.current_subject) do
      json(conn, %{data: Presenter.conversation(result)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, conversation} <-
           Conversations.update_view(id, params, conn.assigns.current_subject) do
      CommsWeb.Broadcast.event(id, "conversation.updated.v1", %{
        title: conversation.title,
        visibility: conversation.visibility,
        version: conversation.version
      })

      json(conn, %{data: Presenter.conversation(conversation)})
    end
  end

  def archive(conn, %{"conversation_id" => id} = params) do
    with {:ok, conversation} <-
           Conversations.archive_view(id, params, conn.assigns.current_subject) do
      CommsWeb.Broadcast.event(id, "conversation.archived.v1", %{
        archived_at: conversation.archived_at,
        version: conversation.version
      })

      json(conn, %{data: Presenter.conversation(conversation)})
    end
  end

  def members(conn, %{"conversation_id" => id}) do
    with {:ok, members} <- Conversations.list_member_views(id, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(members, &Presenter.membership/1)})
    end
  end

  def add_member(conn, %{"conversation_id" => id, "user_id" => user_id} = params) do
    with {:ok, membership} <-
           Conversations.add_member_view(
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

      CommsWeb.Broadcast.conversation_membership(user_id, id, "added")

      conn |> put_status(:created) |> json(%{data: %{id: membership.id}})
    end
  end

  def remove_member(conn, %{"conversation_id" => id, "user_id" => user_id} = params) do
    with {:ok, _membership} <-
           Conversations.remove_member_view(id, user_id, params, conn.assigns.current_subject) do
      CommsWeb.Broadcast.event(id, "membership.changed.v1", %{
        user_id: user_id,
        action: "removed"
      })

      CommsWeb.Broadcast.conversation_membership(user_id, id, "removed")

      send_resp(conn, :no_content, "")
    end
  end

  def update_member(conn, %{"conversation_id" => id, "user_id" => user_id} = params) do
    with {:ok, membership} <-
           Conversations.change_member_role_view(
             id,
             user_id,
             params,
             conn.assigns.current_subject
           ) do
      CommsWeb.Broadcast.event(id, "membership.changed.v1", %{
        user_id: user_id,
        action: "role_changed",
        role: membership.role,
        version: membership.version
      })

      json(conn, %{
        data: %{id: membership.id, role: membership.role, version: membership.version}
      })
    end
  end
end
