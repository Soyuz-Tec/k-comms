defmodule CommsWeb.ServiceConversationController do
  use CommsWeb, :controller

  alias CommsCore.ServiceAccounts

  def index(conn, _params) do
    with {:ok, conversations} <-
           ServiceAccounts.list_conversations(conn.assigns.current_service_subject) do
      json(conn, %{data: Enum.map(conversations, &Presenter.conversation/1)})
    end
  end
end
