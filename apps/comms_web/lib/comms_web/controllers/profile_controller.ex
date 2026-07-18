defmodule CommsWeb.ProfileController do
  use CommsWeb, :controller

  alias CommsCore.Accounts

  def update(conn, params) do
    with {:ok, user} <- Accounts.update_profile_view(params, conn.assigns.current_subject) do
      json(conn, %{data: Presenter.identity_user(user)})
    end
  end

  def password(conn, params) do
    with {:ok, result} <-
           Accounts.change_password_command(params, conn.assigns.current_subject) do
      Enum.each(result.revoked_session_ids, &disconnect_session/1)
      send_resp(conn, :no_content, "")
    end
  end

  def step_up(conn, params) do
    with {:ok, session} <- Accounts.step_up_view(params, conn.assigns.current_subject) do
      json(conn, %{data: %{step_up_at: session.step_up_at}})
    end
  end

  def devices(conn, _params) do
    data =
      conn.assigns.current_subject
      |> Accounts.list_device_views()
      |> Enum.map(&Presenter.device/1)

    json(conn, %{data: data})
  end

  def revoke_device(conn, %{"id" => id}) do
    with {:ok, result} <- Accounts.revoke_device_command(id, conn.assigns.current_subject) do
      Enum.each(result.revoked_session_ids, &disconnect_session/1)
      send_resp(conn, :no_content, "")
    end
  end

  def sessions(conn, _params) do
    data =
      conn.assigns.current_subject
      |> Accounts.list_session_views()
      |> Enum.map(&Presenter.session/1)

    json(conn, %{data: data})
  end

  def revoke_session(conn, %{"id" => id}) do
    with :ok <- Accounts.revoke_own_session_command(id, conn.assigns.current_subject) do
      disconnect_session(id)
      send_resp(conn, :no_content, "")
    end
  end

  defp disconnect_session(session_id) do
    CommsWeb.Endpoint.broadcast("session_socket:#{session_id}", "disconnect", %{})
  end
end
