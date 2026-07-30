defmodule CommsWeb.ConversationChannel.AccessPolicy do
  @moduledoc false

  alias CommsCore.Conversations

  def subject(socket) do
    Map.take(socket.assigns, [
      :tenant_id,
      :user_id,
      :device_id,
      :session_id,
      :role,
      :account_type,
      :guest_conversation_id,
      :guest_admission_id,
      :guest_history_from_sequence,
      :guest_expires_at
    ])
  end

  def authorize(socket, :read),
    do:
      with(
        :ok <- conversation_allowed(socket, socket.assigns.conversation_id),
        do: Conversations.authorize_read(socket.assigns.conversation_id, subject(socket))
      )

  def authorize(socket, :send_message),
    do:
      with(
        :ok <- conversation_allowed(socket, socket.assigns.conversation_id),
        do:
          Conversations.authorize_send_message(
            socket.assigns.conversation_id,
            subject(socket)
          )
      )

  def authorize(socket, :mark_read),
    do:
      with(
        :ok <- conversation_allowed(socket, socket.assigns.conversation_id),
        do: Conversations.authorize_mark_read(socket.assigns.conversation_id, subject(socket))
      )

  def conversation_allowed(socket, conversation_id) do
    case socket.assigns[:account_type] do
      account_type when account_type in [:guest, "guest"] ->
        with true <- socket.assigns[:guest_conversation_id] == conversation_id,
             :ok <- guest_claim_deadline_allowed(socket) do
          :ok
        else
          _ -> {:error, :forbidden}
        end

      _ ->
        :ok
    end
  end

  defp guest_claim_deadline_allowed(%{assigns: %{ephemeral_room_id: room_id}})
       when is_binary(room_id),
       do: :ok

  defp guest_claim_deadline_allowed(socket) do
    case socket.assigns[:guest_expires_at] do
      %DateTime{} = expires_at ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
          do: :ok,
          else: {:error, :forbidden}

      _ ->
        {:error, :forbidden}
    end
  end
end
