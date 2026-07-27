defmodule CommsWeb.SearchController do
  use CommsWeb, :controller

  alias CommsCore.Messaging

  def index(conn, %{"q" => query} = params) do
    include_sender_labels = params["include"] == "sender_labels"

    with {:ok, result} <-
           Messaging.search_page(query, conn.assigns.current_subject,
             limit: params["limit"] || 50,
             cursor: params["cursor"],
             conversation_id: params["conversation_id"],
             sender_user_id: params["sender_user_id"],
             after: params["after"],
             before: params["before"],
             include_sender_labels: include_sender_labels
           ) do
      response = %{
        data: Enum.map(result.messages, &Presenter.message/1),
        page: %{
          limit: result.limit,
          has_more: result.has_more,
          next_cursor: result.next_cursor
        }
      }

      response =
        if include_sender_labels do
          Map.put(response, :included, %{
            sender_labels: Enum.map(result.sender_labels, &Presenter.retained_sender_label/1)
          })
        else
          response
        end

      json(conn, response)
    end
  end

  def index(_conn, _params), do: {:error, :search_query_required}
end
