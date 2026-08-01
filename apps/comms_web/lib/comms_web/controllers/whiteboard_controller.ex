defmodule CommsWeb.WhiteboardController do
  use CommsWeb, :controller

  alias CommsCore.Whiteboards
  alias CommsWeb.{Broadcast, Presenter}

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, page} <-
           Whiteboards.list_operations(conversation_id, conn.assigns.current_subject,
             after_sequence: params["after_sequence"] || 0,
             limit: params["limit"] || 500
           ) do
      json(conn, %{
        data: Enum.map(page.operations, &Presenter.whiteboard_operation/1),
        page: %{
          has_more: page.has_more,
          next_after_sequence: page.next_after_sequence
        }
      })
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with [idempotency_key] <- get_req_header(conn, "idempotency-key"),
         true <- byte_size(idempotency_key) in 8..128 || {:error, :invalid_whiteboard_operation},
         {:ok, operation, status} <-
           Whiteboards.append_operation(
             conversation_id,
             %{
               client_operation_id: idempotency_key,
               base_sequence: params["base_sequence"],
               kind: params["kind"],
               payload: params["payload"] || %{}
             },
             conn.assigns.current_subject
           ) do
      payload = Presenter.whiteboard_operation(operation)

      if status == :created do
        Broadcast.whiteboard_event(
          conversation_id,
          "whiteboard.operation_applied.v1",
          payload
        )
      end

      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> json(%{data: payload})
    else
      [] -> {:error, :idempotency_key_required}
      [_ | _] -> {:error, :invalid_whiteboard_operation}
      {:error, _} = error -> error
    end
  end
end
