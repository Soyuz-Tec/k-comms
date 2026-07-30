defmodule CommsWeb.ConversationChannel.EphemeralPresence do
  @moduledoc false

  alias CommsCore.Conversations
  alias CommsWeb.ConversationChannel.AccessPolicy

  import Phoenix.Socket, only: [assign: 3]

  def open(socket, conversation_id) do
    case Conversations.ephemeral_room_for_conversation(
           conversation_id,
           AccessPolicy.subject(socket)
         ) do
      {:ok, nil} ->
        {:ok, assign(socket, :ephemeral_room_id, nil)}

      {:ok, room} ->
        socket =
          socket
          |> assign(:conversation_id, conversation_id)
          |> assign(:ephemeral_room_id, room.id)
          |> assign(:ephemeral_connection_id, connection_id())

        case Conversations.open_ephemeral_presence(attrs(socket)) do
          {:ok, _result} -> {:ok, socket}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def heartbeat(socket), do: Conversations.heartbeat_ephemeral_presence(attrs(socket))

  def close(%{assigns: %{ephemeral_room_id: room_id}} = socket) when is_binary(room_id),
    do: Conversations.close_ephemeral_presence(attrs(socket))

  def close(_socket), do: :ok

  def heartbeat_delay_ms do
    Application.get_env(:comms_core, :instant_room_presence_heartbeat_seconds, 30)
    |> max(1)
    |> min(60)
    |> Kernel.*(1_000)
  end

  defp attrs(socket) do
    %{
      conversation_id: socket.assigns[:conversation_id],
      connection_id: socket.assigns[:ephemeral_connection_id],
      tenant_id: socket.assigns[:tenant_id],
      user_id: socket.assigns[:user_id],
      device_id: socket.assigns[:device_id],
      session_id: socket.assigns[:session_id]
    }
  end

  defp connection_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
