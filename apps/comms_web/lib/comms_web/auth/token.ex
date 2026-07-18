defmodule CommsWeb.Auth.Token do
  @behaviour CommsWeb.Auth

  @impl true
  def authenticate(params, _connect_info) do
    ticket = params["socket_ticket"] || params[:socket_ticket]

    CommsCore.Accounts.consume_socket_ticket(ticket)
  end
end
