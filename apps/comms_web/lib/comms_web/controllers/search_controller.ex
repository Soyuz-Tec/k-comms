defmodule CommsWeb.SearchController do
  use CommsWeb, :controller

  alias CommsCore.{Attachments, Messaging, Whiteboards}

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
           ),
         {:ok, whiteboards} <-
           Whiteboards.search(query, conn.assigns.current_subject,
             limit: params["workspace_limit"] || 25,
             conversation_id: params["conversation_id"]
           ),
         {:ok, files} <-
           Attachments.list_files(conn.assigns.current_subject, %{
             q: query,
             conversation_id: params["conversation_id"],
             limit: params["workspace_limit"] || 25
           }) do
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

      response =
        if files.files == [] and whiteboards == [] do
          response
        else
          Map.update(response, :included, %{}, fn included -> included end)
          |> update_in([:included], fn included ->
            included
            |> Map.put(:files, Enum.map(files.files, &Presenter.file/1))
            |> Map.put(:whiteboards, Enum.map(whiteboards, &whiteboard_result/1))
          end)
        end

      json(conn, response)
    end
  end

  def index(_conn, _params), do: {:error, :search_query_required}

  defp whiteboard_result(result) do
    %{
      conversation_id: result.conversation_id,
      element_id: result.element_id,
      sequence: result.sequence,
      text: result.text,
      inserted_at: result.inserted_at
    }
  end
end
