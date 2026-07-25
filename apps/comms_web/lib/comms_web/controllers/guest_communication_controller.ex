defmodule CommsWeb.GuestCommunicationController do
  @moduledoc """
  Explicit allowlist for guest communication.

  The conversation id is taken only from the verified guest admission assigned
  by `AuthenticateGuest`; no guest route accepts a caller-selected room id.
  """

  use CommsWeb, :controller

  alias CommsCore.{Accounts, Conversations}

  def show_conversation(conn, _params) do
    with {:ok, conversation} <-
           Conversations.get_for_user_view(conversation_id(conn), conn.assigns.current_subject) do
      json(conn, %{data: Presenter.conversation(conversation)})
    end
  end

  def members(conn, _params) do
    with {:ok, members} <-
           Conversations.list_member_views(
             conversation_id(conn),
             conn.assigns.current_subject
           ) do
      json(conn, %{data: Enum.map(members, &Presenter.guest_membership/1)})
    end
  end

  def messages(conn, params) do
    CommsWeb.MessageController.index(conn, scoped(params, conn))
  end

  def create_message(conn, params) do
    CommsWeb.MessageController.create(conn, scoped(params, conn))
  end

  def update_read_cursor(conn, params) do
    CommsWeb.ReadCursorController.update(conn, scoped(params, conn))
  end

  def socket_ticket(conn, _params) do
    with {:ok, result} <- Accounts.issue_guest_socket_ticket(conn.assigns.current_subject) do
      conn
      |> put_status(:created)
      |> json(%{data: %{ticket: result.ticket, expires_in: result.expires_in}})
    end
  end

  def show_call(conn, params) do
    CommsWeb.AudioCallController.show(conn, scoped(params, conn))
  end

  def create_call(conn, params) do
    CommsWeb.AudioCallController.create(conn, scoped(params, conn))
  end

  def join_call(conn, params) do
    CommsWeb.AudioCallController.join(conn, scoped(params, conn))
  end

  def end_call(conn, params) do
    CommsWeb.AudioCallController.end_call(conn, scoped(params, conn))
  end

  defp scoped(params, conn) do
    params
    |> Map.drop(["conversation_id", :conversation_id])
    |> Map.put("conversation_id", conversation_id(conn))
  end

  defp conversation_id(conn), do: conn.assigns.current_guest_claims["conversation_id"]
end
