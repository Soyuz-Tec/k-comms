defmodule CommsWeb.SharedDocumentController do
  use CommsWeb, :controller
  alias CommsCore.SharedDocuments

  plug(:private_response)

  def index(conn, %{"conversation_id" => id} = params) do
    with {:ok, documents} <-
           SharedDocuments.list(id, params["q"] || "", conn.assigns.current_subject),
         do: json(conn, %{data: Enum.map(documents, &projection/1)})
  end

  def create(conn, %{"conversation_id" => id} = params) do
    with {:ok, document} <-
           SharedDocuments.create(
             id,
             %{client_document_id: params["client_document_id"], title: params["title"]},
             conn.assigns.current_subject
           ),
         do: conn |> put_status(:created) |> json(%{data: projection(document)})
  end

  def show(conn, %{"document_id" => id}) do
    with {:ok, document} <- SharedDocuments.get(id, conn.assigns.current_subject),
         do: json(conn, %{data: projection(document)})
  end

  def copy(conn, %{"document_id" => id} = params) do
    with {:ok, document} <-
           SharedDocuments.copy(
             id,
             %{client_document_id: params["client_document_id"], title: params["title"]},
             conn.assigns.current_subject
           ),
         do: conn |> put_status(:created) |> json(%{data: projection(document)})
  end

  def operation(conn, %{"document_id" => id} = params) do
    attrs = %{
      client_operation_id: params["client_operation_id"],
      generation: params["generation"],
      base_version: params["base_version"],
      kind: params["kind"],
      changes: params["changes"],
      title: params["title"]
    }

    with {:ok, operation, status} <-
           SharedDocuments.apply_operation(id, attrs, conn.assigns.current_subject) do
      payload = projection(operation)

      if status == :created,
        do:
          CommsWeb.Endpoint.broadcast("document:" <> id, "document.operation_applied.v1", payload)

      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> json(%{data: payload})
    end
  end

  def replay(conn, %{"document_id" => id} = params) do
    with {:ok, generation} <- integer(params["generation"], 1),
         {:ok, after_version} <- integer(params["after_version"], 0),
         {:ok, limit} <- integer(params["limit"], 100),
         {:ok, page} <-
           SharedDocuments.replay(
             id,
             generation,
             after_version,
             limit,
             conn.assigns.current_subject
           ) do
      json(conn, %{
        data: Enum.map(page.operations, &projection/1),
        page: %{
          generation: page.generation,
          through_version: page.through_version,
          next_after_version: page.next_after_version,
          has_more: page.has_more
        }
      })
    end
  end

  def export(conn, %{"document_id" => id}) do
    with {:ok, document} <- SharedDocuments.export(id, conn.assigns.current_subject) do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", "attachment; filename=\"k-comms-document.txt\"")
      |> put_resp_header("x-document-version", Integer.to_string(document.version))
      |> put_resp_header("x-document-generation", Integer.to_string(document.generation))
      |> send_resp(:ok, document.title <> "\n\n" <> document.content)
    end
  end

  defp private_response(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

  defp projection(value), do: Map.from_struct(value)
  defp integer(nil, default), do: {:ok, default}
  defp integer(value, _) when is_integer(value), do: {:ok, value}

  defp integer(value, _) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_document_operation}
    end
  end

  defp integer(_, _), do: {:error, :invalid_document_operation}
end
