defmodule CommsWeb.PasswordRecoveryController do
  use CommsWeb, :controller

  alias CommsCore.PasswordRecovery

  def request(conn, params) do
    :ok = PasswordRecovery.request(params)

    conn
    |> put_status(:accepted)
    |> json(%{data: %{status: "accepted"}})
  end

  def reset(conn, params) do
    with {:ok, result} <- PasswordRecovery.reset(params) do
      Enum.each(result.revoked_session_ids, &disconnect_session/1)
      send_resp(conn, :no_content, "")
    end
  end

  defp disconnect_session(session_id) do
    CommsWeb.Endpoint.broadcast("session_socket:#{session_id}", "disconnect", %{})
  end
end
