defmodule CommsWeb.ConversationChannel.RateLimit do
  @moduledoc false

  alias CommsWeb.ConversationChannel.AccessPolicy

  @message_limit 60
  @message_window_seconds 60
  @typing_limit 30
  @typing_window_seconds 10

  def allow(socket, action) when action in [:message, :typing] do
    {limit, window} =
      case action do
        :message -> {@message_limit, @message_window_seconds}
        :typing -> {@typing_limit, @typing_window_seconds}
      end

    key = {
      :conversation_channel,
      action,
      socket.assigns[:session_id] || socket.assigns[:user_id],
      socket.assigns[:conversation_id]
    }

    with true <- CommsWeb.RateLimiter.allow?(key, limit, window),
         :ok <- allow_distributed(socket, action) do
      :ok
    else
      _ -> {:error, :rate_limited}
    end
  end

  defp allow_distributed(%{assigns: %{ephemeral_room_id: room_id}} = socket, :message)
       when is_binary(room_id) do
    case CommsWeb.InstantRoomMessageRateLimit.consume(
           socket.assigns[:conversation_id],
           AccessPolicy.subject(socket)
         ) do
      :ok -> :ok
      {:error, :rate_limited, _retry_after} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allow_distributed(_socket, _action), do: :ok
end
