defmodule CommsWeb.InstantRoomWhiteboardRateLimit do
  @moduledoc false

  alias CommsCore.{Conversations, PlatformRateLimits}
  alias CommsWeb.Plugs.DistributedRateLimit

  @window_seconds 60

  def check(conversation_id, subject) when is_binary(conversation_id) and is_map(subject) do
    case Conversations.ephemeral_room_for_conversation(conversation_id, subject) do
      {:ok, nil} -> :ok
      {:ok, _room} -> consume(conversation_id, subject)
      {:error, reason} -> {:error, reason}
    end
  end

  def check(_conversation_id, _subject), do: {:error, :forbidden}

  defp consume(conversation_id, subject) do
    with tenant_id when is_binary(tenant_id) <- value(subject, :tenant_id),
         user_id when is_binary(user_id) <- value(subject, :user_id),
         session_id when is_binary(session_id) <- value(subject, :session_id) do
      material = [
        "identity-room",
        0,
        tenant_id,
        0,
        user_id,
        0,
        session_id,
        0,
        conversation_id
      ]

      key_digest = DistributedRateLimit.key_digest(:instant_room_whiteboard, material)

      limit =
        Application.get_env(:comms_core, :instant_room_whiteboard_rate_limit, 240)
        |> max(1)

      case PlatformRateLimits.allow?(
             :instant_room_whiteboard,
             key_digest,
             limit,
             @window_seconds
           ) do
        %{allowed: true} -> :ok
        %{allowed: false, retry_after: retry_after} -> {:error, :rate_limited, retry_after}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
