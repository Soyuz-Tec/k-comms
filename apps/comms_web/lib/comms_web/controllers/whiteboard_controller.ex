defmodule CommsWeb.WhiteboardController do
  use CommsWeb, :controller

  alias CommsCore.Whiteboards
  alias CommsWeb.{Broadcast, Presenter}

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, page} <-
           Whiteboards.list_operations(conversation_id, conn.assigns.current_subject,
             after_sequence: params["after_sequence"] || 0,
             limit: params["limit"] || 500,
             snapshot: truthy?(params["snapshot"])
           ) do
      json(conn, %{
        data: Enum.map(page.operations, &Presenter.whiteboard_operation/1),
        snapshot: Presenter.whiteboard_snapshot(page.snapshot),
        page: %{
          has_more: page.has_more,
          next_after_sequence: page.next_after_sequence
        }
      })
    end
  end

  # Query parameters arrive as strings. Anything other than an explicit opt-in
  # means the caller wants the full replay, which is always correct.
  defp truthy?(value), do: value in [true, "true", "1"]

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with [idempotency_key] <- get_req_header(conn, "idempotency-key"),
         true <- byte_size(idempotency_key) in 8..128 || {:error, :invalid_whiteboard_operation},
         :ok <-
           CommsWeb.InstantRoomWhiteboardRateLimit.check(
             conversation_id,
             conn.assigns.current_subject
           ),
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
      {:error, :rate_limited, retry_after} -> rate_limited(conn, retry_after)
      {:error, _} = error -> error
    end
  end

  defp rate_limited(conn, retry_after) do
    retry_after = max(retry_after, 1)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        code: "rate_limited",
        detail: "Too many requests",
        retry_after: retry_after
      }
    })
  end
end
