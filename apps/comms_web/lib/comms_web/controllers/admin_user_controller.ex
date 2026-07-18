defmodule CommsWeb.AdminUserController do
  use CommsWeb, :controller

  alias CommsCore.{Accounts, Governance}

  def index(conn, _params) do
    with {:ok, users} <- Accounts.list_admin_user_views(conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(users, &Presenter.admin_user/1)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, result} <-
           Governance.change_user_lifecycle_view(id, params, conn.assigns.current_subject) do
      Enum.each(result.revoked_session_ids, &disconnect_session/1)
      json(conn, %{data: Presenter.admin_user(result.user)})
    end
  end

  def sessions(conn, %{"user_id" => user_id}) do
    with {:ok, sessions} <-
           Accounts.list_user_session_views(user_id, conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(sessions, &Presenter.session/1)})
    end
  end

  def revoke_session(conn, %{"user_id" => user_id, "id" => id} = params) do
    with :ok <-
           Accounts.admin_revoke_session_command(
             user_id,
             id,
             params,
             conn.assigns.current_subject
           ) do
      disconnect_session(id)
      send_resp(conn, :no_content, "")
    end
  end

  defp disconnect_session(session_id) do
    CommsWeb.Endpoint.broadcast("session_socket:#{session_id}", "disconnect", %{})
  end
end
