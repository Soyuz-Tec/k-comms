defmodule CommsWeb.ConversationChannel do
  use CommsWeb, :channel
  alias CommsCore.{Authorization, Messaging}
  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    subject = Map.take(socket.assigns, [:tenant_id, :user_id, :device_id])
    case Authorization.authorize(:join_conversation, subject, %{id: conversation_id}) do
      :ok -> {:ok, assign(socket, :conversation_id, conversation_id)}
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end
  @impl true
  def handle_in("message.send", payload, socket) do
    attrs = Map.merge(payload, %{tenant_id: socket.assigns.tenant_id, conversation_id: socket.assigns.conversation_id, sender_user_id: socket.assigns.user_id, sender_device_id: socket.assigns.device_id})
    subject = Map.take(socket.assigns, [:tenant_id, :user_id, :device_id])
    case Messaging.accept_message(attrs, subject) do
      {:ok, message} ->
        event = %{id: message.id, conversation_id: message.conversation_id, conversation_sequence: message.conversation_sequence, sender_user_id: message.sender_user_id, body: message.body, inserted_at: message.inserted_at}
        broadcast!(socket, "message.created.v1", event)
        {:reply, {:ok, event}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end
end
