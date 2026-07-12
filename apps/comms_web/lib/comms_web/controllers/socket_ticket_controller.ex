defmodule CommsWeb.SocketTicketController do
  use CommsWeb, :controller

  alias CommsCore.Accounts

  def create(conn, _params) do
    with {:ok, result} <- Accounts.issue_socket_ticket(conn.assigns.current_subject) do
      conn
      |> put_status(:created)
      |> json(%{data: %{ticket: result.ticket, expires_in: result.expires_in}})
    end
  end
end
