defmodule CommsWeb.ConversationChannel.EventVisibility do
  @moduledoc false

  alias CommsCore.Messaging
  alias CommsWeb.ConversationChannel.AccessPolicy

  @message_events [
    "message.created.v1",
    "message.updated.v1",
    "message.deleted.v1",
    "message.reaction_added.v1",
    "message.reaction_removed.v1"
  ]

  def authorize(event, payload, socket) when event in @message_events do
    case socket.assigns[:account_type] do
      account_type when account_type in [:guest, "guest"] ->
        authorize_guest_message_event(payload, socket)

      _ ->
        :ok
    end
  end

  def authorize(_event, _payload, _socket), do: :ok

  defp authorize_guest_message_event(payload, socket) when is_map(payload) do
    with history_from_sequence
         when is_integer(history_from_sequence) and history_from_sequence > 0 <-
           socket.assigns[:guest_history_from_sequence] do
      case event_sequence(payload) do
        sequence when is_integer(sequence) ->
          if sequence >= history_from_sequence, do: :ok, else: {:error, :hidden}

        nil ->
          authorize_guest_message_id(payload, socket)

        _invalid_sequence ->
          {:error, :hidden}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_guest_message_event(_payload, _socket), do: {:error, :hidden}

  defp authorize_guest_message_id(payload, socket) do
    case event_message_id(payload) do
      message_id when is_binary(message_id) ->
        case Messaging.message_event_visible?(
               socket.assigns.conversation_id,
               message_id,
               AccessPolicy.subject(socket)
             ) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, :hidden}
          {:error, _reason} -> {:error, :forbidden}
        end

      _ ->
        {:error, :hidden}
    end
  end

  defp event_sequence(payload) do
    case Map.get(payload, :conversation_sequence) || Map.get(payload, "conversation_sequence") do
      sequence when is_integer(sequence) ->
        sequence

      sequence when is_binary(sequence) ->
        case Integer.parse(sequence) do
          {parsed, ""} -> parsed
          _ -> :invalid
        end

      nil ->
        nil

      _ ->
        :invalid
    end
  end

  defp event_message_id(payload) do
    Map.get(payload, :message_id) || Map.get(payload, "message_id") ||
      Map.get(payload, :id) || Map.get(payload, "id")
  end
end
