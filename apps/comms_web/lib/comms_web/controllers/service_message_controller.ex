defmodule CommsWeb.ServiceMessageController do
  use CommsWeb, :controller

  alias CommsCore.ServiceAccounts
  alias CommsWeb.Broadcast

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    limit = params["limit"] |> integer(100) |> max(1) |> min(200)

    opts = [
      after_sequence: params["after_sequence"] || 0,
      before_sequence: params["before_sequence"],
      limit: limit + 1
    ]

    with {:ok, messages} <-
           ServiceAccounts.list_messages(
             conversation_id,
             conn.assigns.current_service_subject,
             opts
           ) do
      has_more = length(messages) > limit
      page = Enum.take(messages, limit)

      next_sequence =
        page |> List.last() |> then(&if(&1, do: &1.conversation_sequence, else: nil))

      json(conn, %{
        data: Enum.map(page, &Presenter.message/1),
        page: %{
          has_more: has_more,
          next_after_sequence: next_sequence,
          reset_required: false
        }
      })
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    subject = conn.assigns.current_service_subject

    with [idempotency_key] <- get_req_header(conn, "idempotency-key"),
         true <- byte_size(idempotency_key) in 8..128 || {:error, :invalid_idempotency_key},
         attrs <- Map.put(params, "client_message_id", idempotency_key),
         {:ok, message, status} <- ServiceAccounts.send_message(conversation_id, attrs, subject) do
      payload = Presenter.message(message)

      if status == :created do
        Broadcast.event(conversation_id, "message.created.v1", payload)

        Broadcast.conversation_activity(
          conversation_id,
          message.conversation_sequence,
          "message.created.v1"
        )
      end

      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> json(%{data: payload, replayed: status == :duplicate})
    else
      [] -> {:error, :idempotency_key_required}
      [_ | _] -> {:error, :invalid_idempotency_key}
      {:error, _} = error -> error
    end
  end

  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_, default), do: default
end
