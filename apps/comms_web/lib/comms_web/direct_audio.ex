defmodule CommsWeb.DirectAudio do
  @moduledoc """
  Runtime policy for the optional one-to-one WebRTC audio path.

  K-Comms remains the authoritative call control plane and LiveKit remains the
  fallback media plane. This module only permits direct signaling for an
  admitted participant in an active direct-conversation audio call.
  """

  alias CommsCore.{AudioCalls, Conversations}

  @default_stun_urls ["stun:stun.cloudflare.com:3478"]

  def enabled? do
    Application.get_env(:comms_web, :direct_audio_p2p_enabled, false) == true
  end

  def ice_servers do
    urls = Application.get_env(:comms_web, :direct_audio_stun_urls, @default_stun_urls)

    if enabled?() and valid_stun_urls?(urls), do: [%{urls: urls}], else: []
  end

  def authorize(conversation_id, call_id, subject) do
    with true <- enabled?(),
         {:ok, conversation} <- Conversations.get_for_user_view(conversation_id, subject),
         :direct <- conversation.kind,
         {:ok, call} <- AudioCalls.get_active(conversation_id, subject, :audio),
         true <- not is_nil(call) and call.id == call_id,
         :ok <- AudioCalls.authorize_participant(conversation_id, call_id, subject),
         [_server | _] <- ice_servers() do
      :ok
    else
      _ -> {:error, :direct_audio_unavailable}
    end
  end

  defp valid_stun_urls?(urls) when is_list(urls) and length(urls) in 1..4 do
    Enum.all?(urls, fn
      url when is_binary(url) ->
        byte_size(url) in 8..512 and
          (String.starts_with?(url, "stun:") or String.starts_with?(url, "stuns:")) and
          not String.contains?(url, [" ", "\t", "\r", "\n"])

      _ ->
        false
    end)
  end

  defp valid_stun_urls?(_urls), do: false
end
