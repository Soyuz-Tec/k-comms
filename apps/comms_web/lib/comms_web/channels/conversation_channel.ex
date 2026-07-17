defmodule CommsWeb.ConversationChannel do
  use CommsWeb, :channel

  alias CommsCore.{Authorization, Conversations, Messaging}
  alias CommsWeb.Presenter

  @authorized_events [
    "conversation.updated.v1",
    "conversation.archived.v1",
    "message.created.v1",
    "message.updated.v1",
    "message.deleted.v1",
    "message.reaction_added.v1",
    "message.reaction_removed.v1",
    "membership.changed.v1",
    "conversation.read.v1",
    "presence_diff",
    "typing.v1",
    "typing.start",
    "typing.stop"
  ]

  intercept(@authorized_events)

  @impl true
  def join("conversation:" <> conversation_id, payload, socket) do
    subject = subject(socket)
    after_sequence = integer(payload["after_sequence"] || payload[:after_sequence], 0)

    with {:ok, _conversation} <- Conversations.get_for_user_view(conversation_id, subject),
         {:ok, replay_messages} <-
           Messaging.list_history(conversation_id, subject,
             after_sequence: after_sequence,
             limit: 501,
             probe_more: true
           ) do
      {messages, has_more, next_after_sequence} = replay_page(replay_messages, after_sequence)
      socket = assign(socket, :conversation_id, conversation_id)
      send(self(), :after_join)

      {:ok,
       %{
         messages: Enum.map(messages, &Presenter.message/1),
         has_more: has_more,
         next_after_sequence: next_after_sequence
       }, socket}
    else
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    case authorize_command(:read_conversation, socket) do
      :ok ->
        {:ok, _} =
          CommsWeb.Presence.track(socket, socket.assigns.user_id, %{
            device_id: socket.assigns.device_id,
            online_at: System.system_time(:second)
          })

        push(socket, "presence_state", CommsWeb.Presence.list(socket))
        {:noreply, socket}

      {:error, _reason} ->
        {:stop, :unauthorized, socket}
    end
  end

  @impl true
  def handle_in(
        "command",
        %{"command_id" => command_id, "type" => type, "payload" => payload},
        socket
      )
      when is_binary(command_id) and is_binary(type) and is_map(payload) do
    if valid_command_id?(command_id) do
      dispatch_command(type, command_id, payload, socket)
    else
      invalid_command(socket)
    end
  end

  def handle_in("command", _payload, socket), do: invalid_command(socket)

  def handle_in("message.send", payload, socket) do
    attrs =
      Map.merge(payload, %{
        tenant_id: socket.assigns.tenant_id,
        conversation_id: socket.assigns.conversation_id,
        sender_user_id: socket.assigns.user_id,
        sender_device_id: socket.assigns.device_id
      })

    with :ok <- authorize_command(:send_message, socket),
         {:ok, message, status} <-
           Messaging.accept_message_with_status(attrs, subject(socket)) do
      event = Presenter.message(message)

      if status == :created do
        broadcast!(socket, "message.created.v1", event)

        CommsWeb.Broadcast.conversation_activity(
          socket.assigns.conversation_id,
          message.conversation_sequence,
          "message.created.v1"
        )
      end

      {:reply, {:ok, event}, socket}
    else
      {:error, :forbidden} -> stop_unauthorized(socket)
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("conversation.read", %{"sequence" => sequence}, socket) do
    with :ok <- authorize_command(:mark_read, socket),
         {:ok, stored} <-
           Conversations.mark_read(
             socket.assigns.conversation_id,
             integer(sequence, -1),
             subject(socket)
           ) do
      event = %{user_id: socket.assigns.user_id, sequence: stored}
      broadcast!(socket, "conversation.read.v1", event)
      {:reply, {:ok, event}, socket}
    else
      {:error, :forbidden} -> stop_unauthorized(socket)
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in(event, _payload, socket) when event in ["typing.start", "typing.stop"] do
    case authorize_command(:read_conversation, socket) do
      :ok ->
        broadcast_from!(socket, event, %{user_id: socket.assigns.user_id})
        {:noreply, socket}

      {:error, _reason} ->
        stop_unauthorized(socket)
    end
  end

  @impl true
  def handle_out(event, payload, socket) when event in @authorized_events do
    case authorize_command(:read_conversation, socket) do
      :ok ->
        push(socket, event, payload)
        {:noreply, socket}

      {:error, _reason} ->
        {:stop, :unauthorized, socket}
    end
  end

  defp authorize_command(action, socket) do
    Authorization.authorize(action, subject(socket), %{id: socket.assigns.conversation_id})
  end

  defp dispatch_command("message.send.v1", command_id, payload, socket) do
    handle_in("message.send", Map.put(payload, "client_message_id", command_id), socket)
  end

  defp dispatch_command("conversation.read.v1", _command_id, payload, socket) do
    handle_in("conversation.read", payload, socket)
  end

  defp dispatch_command("typing.start.v1", _command_id, payload, socket) do
    handle_typing_command("started", payload, socket)
  end

  defp dispatch_command("typing.stop.v1", _command_id, payload, socket) do
    handle_typing_command("stopped", payload, socket)
  end

  defp dispatch_command(_type, _command_id, _payload, socket) do
    {:reply, {:error, %{reason: "unsupported_command_type"}}, socket}
  end

  defp invalid_command(socket), do: {:reply, {:error, %{reason: "invalid_command"}}, socket}

  defp handle_typing_command(state, _payload, socket) do
    case authorize_command(:read_conversation, socket) do
      :ok ->
        broadcast_from!(socket, "typing.v1", %{user_id: socket.assigns.user_id, state: state})
        {:noreply, socket}

      {:error, _reason} ->
        stop_unauthorized(socket)
    end
  end

  defp valid_command_id?(command_id) do
    String.length(command_id) in 8..128
  end

  defp replay_page(messages, after_sequence) do
    has_more = length(messages) > 500
    page = Enum.take(messages, 500)

    next_after_sequence =
      case List.last(page) do
        nil -> after_sequence
        message -> message.conversation_sequence
      end

    {page, has_more, next_after_sequence}
  end

  defp stop_unauthorized(socket) do
    {:stop, :unauthorized, {:error, %{reason: "forbidden"}}, socket}
  end

  defp subject(socket) do
    Map.take(socket.assigns, [:tenant_id, :user_id, :device_id, :session_id, :role])
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
