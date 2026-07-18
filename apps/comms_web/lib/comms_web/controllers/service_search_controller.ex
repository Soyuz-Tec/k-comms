defmodule CommsWeb.ServiceSearchController do
  use CommsWeb, :controller

  alias CommsCore.Messaging

  def index(conn, %{"q" => query} = params) do
    with {:ok, messages} <-
           Messaging.search_for_service(query, conn.assigns.current_service_subject,
             limit: params["limit"] || 50
           ) do
      json(conn, %{data: Enum.map(messages, &Presenter.message/1)})
    end
  end

  def index(_conn, _params), do: {:error, :search_query_required}
end
