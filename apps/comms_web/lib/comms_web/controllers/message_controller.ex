defmodule CommsWeb.MessageController do
  use CommsWeb, :controller

  alias CommsCore.Messaging
  alias CommsWeb.Broadcast

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    limit = params["limit"] |> integer(100) |> max(1) |> min(200)

    opts = [
      after_sequence: params["after_sequence"] || 0,
      before_sequence: params["before_sequence"],
      limit: limit + 1
    ]

    with {:ok, messages} <-
           Messaging.list_history(conversation_id, conn.assigns.current_subject, opts) do
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
    subject = conn.assigns.current_subject
    started_at = System.monotonic_time()

    with [idempotency_key] <- get_req_header(conn, "idempotency-key"),
         true <- byte_size(idempotency_key) in 8..128 || {:error, :invalid_idempotency_key},
         attrs <-
           Map.merge(params, %{
             "client_message_id" => idempotency_key,
             tenant_id: subject.tenant_id,
             conversation_id: conversation_id,
             sender_user_id: subject.user_id,
             sender_device_id: subject.device_id
           }),
         {:ok, message, status} <- Messaging.accept_message_with_status(attrs, subject) do
      payload = Presenter.message(message)
      if status == :created, do: Broadcast.event(conversation_id, "message.created.v1", payload)

      duration_seconds =
        System.monotonic_time()
        |> Kernel.-(started_at)
        |> System.convert_time_unit(:native, :microsecond)
        |> Kernel./(1_000_000)

      CommsObservability.execute(
        [:message, :commit],
        %{duration_seconds: duration_seconds},
        %{tenant_id: subject.tenant_id, status: status}
      )

      conn |> put_status(:created) |> json(%{data: payload})
    else
      [] -> {:error, :idempotency_key_required}
      [_ | _] -> {:error, :invalid_idempotency_key}
      {:error, _} = error -> error
    end
  end

  def update(conn, %{"id" => id, "body" => body}) do
    with {:ok, message} <- Messaging.edit_message(id, body, conn.assigns.current_subject) do
      payload = Presenter.message(message)
      Broadcast.event(message.conversation_id, "message.updated.v1", payload)
      json(conn, %{data: payload})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, message} <- Messaging.delete_message(id, conn.assigns.current_subject) do
      payload = Presenter.message(message)
      Broadcast.event(message.conversation_id, "message.deleted.v1", payload)
      json(conn, %{data: payload})
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
