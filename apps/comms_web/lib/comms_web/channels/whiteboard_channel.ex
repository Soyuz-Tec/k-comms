defmodule CommsWeb.WhiteboardChannel do
  use CommsWeb, :channel

  alias CommsCore.Conversations
  alias CommsWeb.ConversationChannel.AccessPolicy

  intercept(["whiteboard.operation_applied.v1", "whiteboard.presence.v1"])

  @impl true
  def join("whiteboard:" <> conversation_id, _payload, socket) do
    subject = AccessPolicy.subject(socket)

    with :ok <- AccessPolicy.conversation_allowed(socket, conversation_id),
         :ok <- Conversations.authorize_use_whiteboard(conversation_id, subject) do
      {:ok, assign(socket, :whiteboard_conversation_id, conversation_id)}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("whiteboard.presence.v1", payload, socket) do
    with :ok <- authorize(socket),
         true <- valid_presence?(payload),
         true <- allow_presence?(socket) do
      broadcast_from!(socket, "whiteboard.presence.v1", %{
        user_id: socket.assigns.user_id,
        device_id: socket.assigns.device_id,
        pointer: payload["pointer"],
        button: payload["button"] == "down",
        selected_element_ids: payload["selected_element_ids"] || []
      })

      {:noreply, socket}
    else
      false -> {:noreply, socket}
      _ -> {:stop, :unauthorized, socket}
    end
  end

  @impl true
  def handle_out("whiteboard.operation_applied.v1", payload, socket) do
    push_if_authorized(socket, "whiteboard.operation_applied.v1", payload)
  end

  def handle_out("whiteboard.presence.v1", payload, socket) do
    push_if_authorized(socket, "whiteboard.presence.v1", payload)
  end

  defp push_if_authorized(socket, event, payload) do
    case authorize(socket) do
      :ok ->
        push(socket, event, payload)
        {:noreply, socket}

      _ ->
        {:stop, :unauthorized, socket}
    end
  end

  defp authorize(socket) do
    conversation_id = socket.assigns.whiteboard_conversation_id

    with :ok <- AccessPolicy.conversation_allowed(socket, conversation_id),
         do: Conversations.authorize_use_whiteboard(conversation_id, AccessPolicy.subject(socket))
  end

  defp allow_presence?(socket) do
    CommsWeb.RateLimiter.allow?(
      {:whiteboard_presence, socket.assigns.session_id},
      60,
      1
    )
  end

  defp valid_presence?(%{"pointer" => %{"x" => x, "y" => y}} = payload)
       when is_number(x) and is_number(y) do
    selected = payload["selected_element_ids"] || []
    tool = get_in(payload, ["pointer", "tool"])

    x >= -1_000_000 and x <= 1_000_000 and y >= -1_000_000 and y <= 1_000_000 and
      is_list(selected) and length(selected) <= 100 and
      Enum.all?(selected, &(is_binary(&1) and byte_size(&1) in 8..128)) and
      tool in ["pointer", "laser"] and
      payload["button"] in ["up", "down", nil]
  end

  defp valid_presence?(_), do: false
end
