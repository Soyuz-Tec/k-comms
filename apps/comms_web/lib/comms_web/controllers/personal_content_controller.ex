defmodule CommsWeb.PersonalContentController do
  use CommsWeb, :controller
  alias CommsCore.Messaging
  alias CommsWeb.Presenter

  def saved(conn, params) do
    with {:ok, page} <- Messaging.saved_items(conn.assigns.current_subject, params),
         do:
           json(conn, %{
             data: Enum.map(page.messages, &Presenter.message/1),
             page: %{
               truncated: page.truncated,
               has_more: page.has_more,
               next_cursor: page.next_cursor
             }
           })
  end

  def save(conn, %{"message_id" => id}) do
    with {:ok, result} <- Messaging.save_message(id, conn.assigns.current_subject),
         do: json(conn, %{data: result})
  end

  def unsave(conn, %{"message_id" => id}) do
    with {:ok, result} <- Messaging.unsave_message(id, conn.assigns.current_subject),
         do: json(conn, %{data: result})
  end

  def draft(conn, %{"conversation_id" => id} = params) do
    with {:ok, result} <- Messaging.get_draft(id, params, conn.assigns.current_subject),
         do: json(conn, %{data: Map.from_struct(result)})
  end

  def update_draft(conn, %{"conversation_id" => id} = params) do
    with {:ok, result} <- Messaging.put_draft(id, params, conn.assigns.current_subject),
         do: json(conn, %{data: Map.from_struct(result)})
  end
end
