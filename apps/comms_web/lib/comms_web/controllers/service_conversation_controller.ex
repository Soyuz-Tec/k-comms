defmodule CommsWeb.ServiceConversationController do
  use CommsWeb, :controller

  alias CommsCore.Conversations

  def index(conn, _params) do
    with {:ok, conversations} <-
           Conversations.list_for_service(conn.assigns.current_service_subject) do
      json(conn, %{data: Enum.map(conversations, &Presenter.conversation/1)})
    end
  end
end
